# frozen_string_literal: true

# Seeds the development DB with five concrete BEFORE-state scenarios for the
# discourse-notification-state-tracker plugin so they can be exercised in the
# admin UI. Run after `bin/rake db:drop db:create db:migrate dev:populate`:
#
#   bin/rails runner plugins/discourse-notification-state-tracker/script/seed_test_scenarios.rb
#
# Then follow the matching TESTING.md.

raise "Refusing to run outside development" unless Rails.env.development?

puts "==> Enabling plugin + tag/category tracking"
SiteSetting.tagging_enabled = true
SiteSetting.discourse_notification_state_tracker_enabled = true
SiteSetting.discourse_notification_state_tracker_track_tags = true
SiteSetting.discourse_notification_state_tracker_track_categories = true

# ---------- groups, tags, category ----------------------------------------

def find_or_make_group(name)
  Group.find_by(name: name) || Group.create!(name: name)
end

def find_or_make_tag(name)
  Tag.find_by(name: name) || Tag.create!(name: name)
end

def find_or_make_category(name)
  Category.find_by(name: name) ||
    Category.create!(name: name, user: Discourse.system_user, color: "0088CC", text_color: "FFFFFF")
end

tracked_eng = find_or_make_group("team_engineering")
tracked_design = find_or_make_group("team_design")
untracked_ext = find_or_make_group("external_contractors")

SiteSetting.discourse_notification_state_tracker_tracked_groups = [
  tracked_eng.id,
  tracked_design.id,
].join("|")

tag_eng = find_or_make_tag("engineering")
tag_design = find_or_make_tag("design")
tag_shared = find_or_make_tag("shared")

announcements = find_or_make_category("Team Announcements")

# These setters stash on @tag_notifications / @category_notifications and the
# save! triggers set_default_notifications → GroupTagNotificationDefault.batch_set.
tracked_eng.watching_tags = [tag_eng.name, tag_shared.name]
tracked_eng.watching_category_ids = [announcements.id]
tracked_eng.save!

tracked_design.watching_tags = [tag_design.name, tag_shared.name]
tracked_design.save!

untracked_ext.watching_tags = [tag_shared.name]
untracked_ext.save!

# ---------- users ---------------------------------------------------------

PASSWORD = "Testpass1234!"

def find_or_make_user(username, name)
  User.find_by(username: username) ||
    User.create!(
      username: username,
      name: name,
      email: "#{username}@example.com",
      password: PASSWORD,
      active: true,
      approved: true,
      trust_level: TrustLevel[1],
    )
end

# dev:populate does not seed an admin, so make sure we have one to sign in with.
admin = find_or_make_user("nst_admin", "Tracker Admin")
admin.update!(admin: true) unless admin.admin?
puts "==> Admin user ready: nst_admin / #{PASSWORD}"

users = {
  clean_join: find_or_make_user("nst_clean_join", "Clean Join"),
  personal_pref: find_or_make_user("nst_personal_pref", "Personal Pref"),
  overlap: find_or_make_user("nst_overlap", "Overlap"),
  post_edit: find_or_make_user("nst_post_edit", "Post Edit"),
  untracked_floor: find_or_make_user("nst_untracked_floor", "Untracked Floor"),
}

# Idempotent reset so this script can be re-run. Wipe snapshots BEFORE removing
# from groups so restore_after_remove sees nothing to do.
puts "==> Resetting test users to a clean slate"
all_groups = [tracked_eng, tracked_design, untracked_ext]
users.each_value do |u|
  DiscourseNotificationStateTracker::Snapshot.where(user_id: u.id).delete_all
  TagUser.where(user_id: u.id).delete_all
  CategoryUser.where(user_id: u.id).delete_all
  all_groups.each { |g| g.remove(u) }
end

tag_levels = TagUser.notification_levels
cat_levels = CategoryUser.notification_levels

# ---------- scenarios -----------------------------------------------------

puts "==> [1/5] nst_clean_join: no prior prefs, added to team_engineering"
tracked_eng.add(users[:clean_join])

puts "==> [2/5] nst_personal_pref: personal tracking/watching, then added"
TagUser.change(users[:personal_pref].id, tag_eng.id, tag_levels[:tracking])
CategoryUser.set_notification_level_for_category(
  users[:personal_pref],
  cat_levels[:watching],
  announcements.id,
)
tracked_eng.add(users[:personal_pref])

puts "==> [3/5] nst_overlap: added to both team_engineering AND team_design"
tracked_eng.add(users[:overlap])
tracked_design.add(users[:overlap])

puts "==> [4/5] nst_post_edit: added to team_engineering, then mutes engineering"
tracked_eng.add(users[:post_edit])
TagUser.change(users[:post_edit].id, tag_eng.id, tag_levels[:muted])

puts "==> [5/5] nst_untracked_floor: added to team_engineering, then to external_contractors"
tracked_eng.add(users[:untracked_floor])
untracked_ext.add(users[:untracked_floor])

# ---------- summary -------------------------------------------------------

def describe_user(user)
  tag_levels = TagUser.notification_levels
  cat_levels = CategoryUser.notification_levels

  tags =
    TagUser
      .where(user_id: user.id)
      .pluck(:tag_id, :notification_level)
      .map { |tid, lvl| "#{Tag.find(tid).name}=#{tag_levels.key(lvl)}" }
  cats =
    CategoryUser
      .where(user_id: user.id)
      .pluck(:category_id, :notification_level)
      .map { |cid, lvl| "#{Category.find(cid).name}=#{cat_levels.key(lvl)}" }
  snaps = DiscourseNotificationStateTracker::Snapshot.where(user_id: user.id).count
  groups =
    GroupUser
      .joins(:group)
      .where(user_id: user.id)
      .where.not(groups: { automatic: true })
      .pluck("groups.name")

  printf "  %-22s groups=%-40s tags=%-50s cats=%-30s snapshots=%d\n",
         user.username,
         "[#{groups.join(", ")}]",
         "[#{tags.join(", ")}]",
         "[#{cats.join(", ")}]",
         snaps
end

puts
puts "Seeded. Current BEFORE-removal state:"
puts
users.each_value { |u| describe_user(u) }
puts
puts "Password for all test users: #{PASSWORD}"
puts "Tracked groups: team_engineering, team_design  (external_contractors is untracked)"
puts "Next: follow plugins/discourse-notification-state-tracker/TESTING.md"
