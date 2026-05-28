# frozen_string_literal: true

module DiscourseNotificationStateTracker
  # Prepended to core GroupManager. The enabled check lives here (not just in
  # enabled_site_setting) because a prepend is permanent for the process and is
  # not undone when the plugin is disabled.
  module GroupManagerExtension
    # The single funnel for applying a group's notification defaults on join
    # (both group.add/bulk_add and GroupUser.create reach it). Snapshot BEFORE
    # super so we read the pre-mutation tag_users/category_users state.
    def sync_add_side_effects(added_user_ids)
      if SiteSetting.discourse_notification_state_tracker_enabled
        StateTracker.snapshot_before_add(@group, added_user_ids)
      end
      super
    end

    # Covers the GroupUser#destroy / usernames= removal paths, which do NOT fire
    # :user_removed_from_group. Idempotent with the event listener in plugin.rb.
    def sync_removal_side_effects(removed_user_ids)
      super
      if SiteSetting.discourse_notification_state_tracker_enabled
        User
          .where(id: removed_user_ids)
          .find_each { |user| StateTracker.restore_after_remove(user, @group) }
      end
    end
  end
end
