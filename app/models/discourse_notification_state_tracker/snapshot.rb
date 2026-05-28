# frozen_string_literal: true

module DiscourseNotificationStateTracker
  # Records a user's tag/category notification level as it was *before* a tracked
  # group applied its notification defaults, so the level can be restored when the
  # user leaves the group. A NULL `notification_level` means the user had no
  # tag_users/category_users row at all (restoring => delete the row).
  class Snapshot < ::ActiveRecord::Base
    self.table_name = "notification_state_tracker_snapshots"

    belongs_to :user
    belongs_to :group

    scope :for_membership, ->(user, group) { where(user_id: user.id, group_id: group.id) }
  end
end

# == Schema Information
#
# Table name: notification_state_tracker_snapshots
#
#  id                 :bigint           not null, primary key
#  user_id            :integer          not null
#  group_id           :integer          not null
#  notifiable_type    :string           not null
#  notifiable_id      :integer          not null
#  notification_level :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  idx_nst_snapshots_baseline  (user_id,notifiable_type,notifiable_id)
#  idx_nst_snapshots_unique    (user_id,group_id,notifiable_type,notifiable_id) UNIQUE
#
