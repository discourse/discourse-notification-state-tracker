# frozen_string_literal: true

# name: discourse-notification-state-tracker
# about: Snapshots a user's tag and category notification levels before a tracked group applies its defaults, and restores them when the user leaves the group.
# meta_topic_id: TODO
# version: 0.0.1
# authors: Discourse
# url: https://github.com/discourse/discourse-notification-state-tracker
# required_version: 2.7.0

enabled_site_setting :discourse_notification_state_tracker_enabled

module ::DiscourseNotificationStateTracker
  PLUGIN_NAME = "discourse-notification-state-tracker"
end

require_relative "lib/discourse_notification_state_tracker/engine"

after_initialize do
  # StateTracker and GroupManagerExtension live under lib/ (added to the engine's
  # autoload paths), so they are referenced directly rather than required here.

  # Snapshot on join: prepend the universal pre-mutation funnel. reloadable_patch
  # keeps the patch in place across dev code reloads.
  reloadable_patch do
    ::GroupManager.prepend(DiscourseNotificationStateTracker::GroupManagerExtension)
  end

  # Restore on removal: this event fires for group.remove / bulk_remove (the API
  # and admin paths). The GroupUser#destroy path is handled by the prepend above.
  on(:user_removed_from_group) do |user, group|
    next unless SiteSetting.discourse_notification_state_tracker_enabled
    DiscourseNotificationStateTracker::StateTracker.restore_after_remove(user, group)
  end
end
