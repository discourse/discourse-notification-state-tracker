# frozen_string_literal: true

RSpec.describe DiscourseNotificationStateTracker::StateTracker do
  fab!(:user)
  fab!(:tracked_group, :group)
  fab!(:other_tracked_group, :group)
  fab!(:untracked_group, :group)
  fab!(:tag1, :tag)
  fab!(:category1, :category)

  before do
    enable_current_plugin
    SiteSetting.discourse_notification_state_tracker_tracked_groups = [
      tracked_group.id,
      other_tracked_group.id,
    ].join("|")
  end

  def tag_levels
    TagUser.notification_levels
  end

  def category_levels
    CategoryUser.notification_levels
  end

  def snapshot_for(user, group, type, id)
    DiscourseNotificationStateTracker::Snapshot.find_by(
      user_id: user.id,
      group_id: group.id,
      notifiable_type: type,
      notifiable_id: id,
    )
  end

  describe ".snapshot_before_add" do
    it "snapshots a NULL baseline when the user had no prior tag notification" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!

      tracked_group.add(user)

      snapshot = snapshot_for(user, tracked_group, "Tag", tag1.id)
      expect(snapshot).to be_present
      expect(snapshot.notification_level).to be_nil
      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to eq([tag1.id])
    end

    it "snapshots the prior level when the user already had a tag notification" do
      TagUser.create!(user: user, tag: tag1, notification_level: tag_levels[:tracking])
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!

      tracked_group.add(user)

      expect(snapshot_for(user, tracked_group, "Tag", tag1.id).notification_level).to eq(
        tag_levels[:tracking],
      )
      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to eq([tag1.id])
    end

    it "snapshots a NULL baseline for a category the user did not track" do
      tracked_group.watching_category_ids = [category1.id]
      tracked_group.save!

      tracked_group.add(user)

      snapshot = snapshot_for(user, tracked_group, "Category", category1.id)
      expect(snapshot).to be_present
      expect(snapshot.notification_level).to be_nil
    end

    it "does not snapshot when the group is not tracked" do
      untracked_group.watching_tags = [tag1.name]
      untracked_group.save!

      expect { untracked_group.add(user) }.not_to change {
        DiscourseNotificationStateTracker::Snapshot.count
      }
    end

    it "does not snapshot when the group is automatic" do
      automatic_group = Fabricate(:group, automatic: true)
      automatic_group.watching_tags = [tag1.name]
      automatic_group.save!
      SiteSetting.discourse_notification_state_tracker_tracked_groups = automatic_group.id.to_s

      expect { automatic_group.add(user) }.not_to change {
        DiscourseNotificationStateTracker::Snapshot.count
      }
    end

    it "does nothing when the plugin is disabled" do
      SiteSetting.discourse_notification_state_tracker_enabled = false
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!

      expect { tracked_group.add(user) }.not_to change {
        DiscourseNotificationStateTracker::Snapshot.count
      }
    end

    it "does not snapshot tags when tag tracking is disabled" do
      SiteSetting.discourse_notification_state_tracker_track_tags = false
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!

      tracked_group.add(user)

      expect(snapshot_for(user, tracked_group, "Tag", tag1.id)).to be_nil
    end

    it "does not snapshot categories when category tracking is disabled" do
      SiteSetting.discourse_notification_state_tracker_track_categories = false
      tracked_group.watching_category_ids = [category1.id]
      tracked_group.save!

      tracked_group.add(user)

      expect(snapshot_for(user, tracked_group, "Category", category1.id)).to be_nil
    end

    it "preserves the true pre-group baseline when a second tracked group grants the same tag" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      other_tracked_group.watching_tags = [tag1.name]
      other_tracked_group.save!

      tracked_group.add(user)
      other_tracked_group.add(user)

      # both memberships record the real pre-group level (NULL), not the value the
      # first group already raised it to
      expect(snapshot_for(user, tracked_group, "Tag", tag1.id).notification_level).to be_nil
      expect(snapshot_for(user, other_tracked_group, "Tag", tag1.id).notification_level).to be_nil
    end
  end

  describe ".restore_after_remove" do
    it "removes a group-added tag the user had no prior level for" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)
      expect(TagUser.where(user: user, tag: tag1).exists?).to eq(true)

      tracked_group.remove(user)

      expect(TagUser.where(user: user, tag: tag1).exists?).to eq(false)
    end

    it "restores the user's prior personal tag level" do
      TagUser.create!(user: user, tag: tag1, notification_level: tag_levels[:tracking])
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)
      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to eq([tag1.id])

      tracked_group.remove(user)

      expect(TagUser.lookup(user, :tracking).pluck(:tag_id)).to eq([tag1.id])
      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to be_empty
    end

    it "leaves a category the user personally watches untouched (clean diff)" do
      CategoryUser.create!(
        user: user,
        category: category1,
        notification_level: category_levels[:watching],
      )
      tracked_group.tracking_category_ids = [category1.id]
      tracked_group.save!
      tracked_group.add(user)
      # the group default (tracking) does not lower the user's own watching
      expect(CategoryUser.lookup(user, :watching).pluck(:category_id)).to eq([category1.id])

      tracked_group.remove(user)

      expect(CategoryUser.lookup(user, :watching).pluck(:category_id)).to eq([category1.id])
    end

    it "keeps a tag that another tracked group still grants, then removes it on the final removal" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      other_tracked_group.watching_tags = [tag1.name]
      other_tracked_group.save!
      tracked_group.add(user)
      other_tracked_group.add(user)

      tracked_group.remove(user)
      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to eq([tag1.id])

      other_tracked_group.remove(user)
      expect(TagUser.where(user: user, tag: tag1).exists?).to eq(false)
    end

    it "keeps a tag that an untracked group the user joined later still grants" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)

      untracked_group.watching_tags = [tag1.name]
      untracked_group.save!
      untracked_group.add(user)

      tracked_group.remove(user)

      expect(TagUser.lookup(user, :watching).pluck(:tag_id)).to eq([tag1.id])
    end

    it "deletes the membership's snapshot rows after restoring" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)

      tracked_group.remove(user)

      expect(
        DiscourseNotificationStateTracker::Snapshot.for_membership(user, tracked_group).count,
      ).to eq(0)
    end

    it "preserves a tag the user muted after the group granted it" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)
      TagUser.change(user.id, tag1.id, tag_levels[:muted])

      tracked_group.remove(user)

      expect(TagUser.lookup(user, :muted).pluck(:tag_id)).to eq([tag1.id])
    end

    it "preserves a category level the user changed after the group granted it" do
      tracked_group.watching_category_ids = [category1.id]
      tracked_group.save!
      tracked_group.add(user)
      CategoryUser.set_notification_level_for_category(
        user,
        category_levels[:tracking],
        category1.id,
      )

      tracked_group.remove(user)

      expect(CategoryUser.lookup(user, :tracking).pluck(:category_id)).to eq([category1.id])
    end

    it "records a fresh baseline when the user is re-added after removal" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)
      tracked_group.remove(user)
      expect(snapshot_for(user, tracked_group, "Tag", tag1.id)).to be_nil

      tracked_group.add(user)

      snapshot = snapshot_for(user, tracked_group, "Tag", tag1.id)
      expect(snapshot).to be_present
      expect(snapshot.notification_level).to be_nil
    end

    it "does nothing when the plugin is disabled at removal time" do
      tracked_group.watching_tags = [tag1.name]
      tracked_group.save!
      tracked_group.add(user)
      SiteSetting.discourse_notification_state_tracker_enabled = false

      tracked_group.remove(user)

      expect(TagUser.where(user: user, tag: tag1).exists?).to eq(true)
    end
  end
end
