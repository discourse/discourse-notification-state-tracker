# Discourse Notification State Tracker

When a user joins a Discourse group, the group's **tag and category notification
defaults** are applied to that user (e.g. a tag is added to their watched tags).
Core does **not** revert those notifications when the user later leaves the group.

This plugin closes that gap. For groups you mark as *tracked*, it snapshots each
user's tag/category notification levels **before** the group applies its defaults,
and **restores** them when the user is removed — reverting only the group's
contribution while leaving the user's own preferences intact.

This lets you drive a user's tag/category notifications entirely through group
membership (add/remove users from a group via the bulk group-members API) and rely
on the membership being correctly reversible, instead of patching each user's
notification preferences individually.

## How it works

- **On add** (`group.add` / bulk add / `GroupUser` create): just before the group
  upserts its notification defaults, the user's current level for each affected
  tag/category is recorded in `notification_state_tracker_snapshots`. A `NULL`
  level means the user had no preference for that tag/category at all. If a
  snapshot already exists for that user+tag/category under another tracked group,
  the earlier (true pre-group) baseline is kept.
- **On removal** (`group.remove` / bulk remove, plus the `GroupUser#destroy`
  path): each snapshotted tag/category is restored to the higher of the user's
  recorded baseline and whatever any group the user *still* belongs to would
  grant. If neither applies, the tag/category notification is removed. The
  snapshot rows for that membership are then deleted.

## Settings

- `discourse_notification_state_tracker_enabled` — master switch (default off).
- `discourse_notification_state_tracker_tracked_groups` — the groups to track.
  Automatic groups (e.g. trust-level groups) are ignored.
- `discourse_notification_state_tracker_track_tags` — track tag notifications
  (default on).
- `discourse_notification_state_tracker_track_categories` — track category
  notifications (default on).

## Known limitations

- **Topic-level watch state is not reverted.** Applying a tag/category default can
  also mark already-existing topics watched/tracked (via `auto_watch`/`auto_track`
  on `topic_users`). The plugin reverts `tag_users`/`category_users` only; it does
  not un-watch individual topics.
- **Defaults edited after a user joins are not snapshotted.** If an admin adds a
  tag/category to a tracked group's defaults and applies it to existing members
  (a path that bypasses the join hook), that tag/category has no baseline, so it is
  left untouched on removal (never wrongly deleted).
- **Pre-existing memberships have no baseline.** Users already in a tracked group
  before the plugin was enabled have no snapshot, so their tag/category
  notifications are not reverted on removal. Snapshots build up as users are added
  after the plugin is live.
- **Automatic groups are intentionally excluded.** Discourse maintains
  `trust_level_0..4`, `admins`, `moderators`, `staff`, and `everyone` itself;
  membership is driven by core, not by admins. Core changes membership on those
  groups via raw `delete_all`, which bypasses both the `:user_removed_from_group`
  event and the `GroupUser#destroy` callback this plugin listens on. The plugin
  would snapshot on add but never see the removal, leaking state. Rather than
  ship something subtly broken, `StateTracker#tracked?` skips any group with
  `automatic: true` even if it's listed in
  `discourse_notification_state_tracker_tracked_groups`. If you genuinely want
  to drive tag/category state via trust-level promotion, the right fix is in
  core — have `Group.user_trust_level_change!` go through `GroupManager` so it
  triggers the removal event — not in this plugin.
