# frozen_string_literal: true

module DiscourseNotificationStateTracker
  # Snapshots a user's tag/category notification levels just before a tracked
  # group applies its notification defaults, and restores them when the user
  # leaves the group — reverting only the group's contribution while leaving the
  # user's own preferences (and other tracked groups' contributions) intact.
  module StateTracker
    # Static, reload-safe config keyed by notifiable_type. Only symbols/strings
    # live here; model classes are resolved lazily (see #defaults_model etc.) so
    # dev-mode code reloading never leaves a stale class reference behind.
    KINDS = {
      "Tag" => {
        setting: :discourse_notification_state_tracker_track_tags,
        join_table: "tag_users",
        join_fk: "tag_id",
        defaults_assoc: :group_tag_notification_defaults,
        defaults_fk: :tag_id,
      },
      "Category" => {
        setting: :discourse_notification_state_tracker_track_categories,
        join_table: "category_users",
        join_fk: "category_id",
        defaults_assoc: :group_category_notification_defaults,
        defaults_fk: :category_id,
      },
    }.freeze

    class << self
      # Called (before super) from GroupManager#sync_add_side_effects, i.e. right
      # before the group upserts its tag/category notification defaults onto the
      # users. Records each affected user's pre-group level so it can be restored.
      def snapshot_before_add(group, user_ids)
        return if user_ids.blank?
        return unless tracked?(group)

        KINDS.each do |type, kind|
          next unless SiteSetting.public_send(kind[:setting])

          notifiable_ids = group.public_send(kind[:defaults_assoc]).pluck(kind[:defaults_fk])
          notifiable_ids.each { |id| insert_snapshots(group.id, type, id, user_ids, kind) }
        end
      end

      # Called from the :user_removed_from_group listener and (for the
      # GroupUser#destroy path) from GroupManager#sync_removal_side_effects.
      # Snapshots are consumed atomically (DELETE ... RETURNING) so a concurrent
      # re-add records a fresh baseline rather than colliding with rows that are
      # about to be deleted, and so the two removal paths are idempotent.
      def restore_after_remove(user, group)
        return unless tracked?(group)

        ActiveRecord::Base.transaction do
          rows = DB.query(<<~SQL, user_id: user.id, group_id: group.id)
              DELETE FROM notification_state_tracker_snapshots
              WHERE user_id = :user_id AND group_id = :group_id
              RETURNING notifiable_type, notifiable_id, notification_level
            SQL
          next if rows.blank?

          group_defaults = leaving_group_defaults(group)
          rows.each { |row| restore_one(user, group, row, group_defaults) }
        end
      end

      def tracked?(group)
        group.present? && !group.automatic && tracked_group_ids.include?(group.id)
      end

      private

      def tracked_group_ids
        SiteSetting.discourse_notification_state_tracker_tracked_groups_map
      end

      # One set-based upsert per notifiable, across all added users (mirrors
      # GroupUser.bulk_set_tag_notifications). The stored level is the user's true
      # pre-group baseline: if a snapshot for this user+notifiable already exists
      # under another tracked group we reuse it (preserving a meaningful NULL);
      # otherwise we capture the current tag_users/category_users level (NULL when
      # there is no row). ON CONFLICT DO NOTHING keeps the earliest baseline.
      def insert_snapshots(group_id, type, notifiable_id, user_ids, kind)
        DB.exec(
          <<~SQL,
          INSERT INTO notification_state_tracker_snapshots
            (user_id, group_id, notifiable_type, notifiable_id, notification_level, created_at, updated_at)
          SELECT
            ids.user_id,
            :group_id,
            :type,
            :notifiable_id,
            CASE
              WHEN existing.found THEN existing.notification_level
              ELSE cur.notification_level
            END,
            NOW(),
            NOW()
          FROM unnest(ARRAY[:user_ids]::int[]) AS ids(user_id)
          LEFT JOIN #{kind[:join_table]} cur
            ON cur.user_id = ids.user_id AND cur.#{kind[:join_fk]} = :notifiable_id
          LEFT JOIN LATERAL (
            SELECT s.notification_level, TRUE AS found
            FROM notification_state_tracker_snapshots s
            WHERE s.user_id = ids.user_id
              AND s.notifiable_type = :type
              AND s.notifiable_id = :notifiable_id
            LIMIT 1
          ) existing ON TRUE
          ON CONFLICT (user_id, group_id, notifiable_type, notifiable_id) DO NOTHING
        SQL
          group_id: group_id,
          type: type,
          notifiable_id: notifiable_id,
          user_ids: user_ids,
        )
      end

      def restore_one(user, group, row, group_defaults)
        type = row.notifiable_type
        return unless KINDS.key?(type)

        nid = row.notifiable_id
        baseline = row.notification_level
        floor = highest_remaining_default(user, group, type, nid)

        # If the user has manually changed this notifiable since the group granted
        # it, their current level no longer matches what the baseline + group
        # defaults would have produced. Leave their explicit choice intact rather
        # than reverting it (the plugin only reverts the group's own contribution).
        group_derived = semantic_higher(baseline, semantic_higher(group_defaults[type][nid], floor))
        return if current_level(user, type, nid) != group_derived

        desired = semantic_higher(baseline, floor)
        if desired.nil?
          delete_level(user, type, nid)
        else
          set_level(user, type, nid, desired)
        end
      end

      # The departing group's own tag/category notification defaults, used to work
      # out what level the group contributed so we can detect later user edits.
      def leaving_group_defaults(group)
        {
          "Tag" => group.group_tag_notification_defaults.pluck(:tag_id, :notification_level).to_h,
          "Category" =>
            group
              .group_category_notification_defaults
              .pluck(:category_id, :notification_level)
              .to_h,
        }
      end

      def current_level(user, type, notifiable_id)
        case type
        when "Tag"
          TagUser.where(user_id: user.id, tag_id: notifiable_id).pick(:notification_level)
        when "Category"
          CategoryUser.where(user_id: user.id, category_id: notifiable_id).pick(:notification_level)
        end
      end

      # The semantically highest default level for this notifiable across ALL of
      # the user's remaining group memberships (tracked or not, automatic or not),
      # so we never strip a tag/category that any group the user still belongs to
      # would grant. This is purely a floor: it can only keep the restored level
      # at or above the user's own baseline, never below it. NULL if none.
      def highest_remaining_default(user, group, type, notifiable_id)
        member_group_ids =
          GroupUser.where(user_id: user.id).where.not(group_id: group.id).pluck(:group_id)
        return nil if member_group_ids.empty?

        levels =
          defaults_model(type).where(
            :group_id => member_group_ids,
            KINDS[type][:defaults_fk] => notifiable_id,
          ).pluck(:notification_level)

        levels.reduce(nil) { |acc, level| semantic_higher(acc, level) }
      end

      # Mirrors GroupUser.semantically_higher_notification_level_sql: notification
      # levels are muted(0) < regular(1) < tracking(2) < watching_first_post(4) <
      # watching(3, ranked as 5). NULL means "no preference" and loses to any real
      # level; the result is NULL only when both inputs are NULL.
      def semantic_higher(level_a, level_b)
        return level_b if level_a.nil?
        return level_a if level_b.nil?

        rank = ->(level) { level == 3 ? 5 : level }
        rank.call(level_a) >= rank.call(level_b) ? level_a : level_b
      end

      def set_level(user, type, notifiable_id, level)
        case type
        when "Tag"
          TagUser.change(user.id, notifiable_id, level)
        when "Category"
          CategoryUser.set_notification_level_for_category(user, level, notifiable_id)
        end
      end

      def delete_level(user, type, notifiable_id)
        case type
        when "Tag"
          TagUser.where(user_id: user.id, tag_id: notifiable_id).delete_all
        when "Category"
          CategoryUser.where(user_id: user.id, category_id: notifiable_id).delete_all
        end
      end

      def defaults_model(type)
        type == "Tag" ? GroupTagNotificationDefault : GroupCategoryNotificationDefault
      end
    end
  end
end
