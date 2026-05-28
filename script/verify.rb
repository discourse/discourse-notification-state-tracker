# frozen_string_literal: true

# Exercises each seeded scenario end-to-end against the development DB:
# performs the removal, prints BEFORE/AFTER, and asserts the EXPECTED state.
# Run after seed_test_scenarios.rb has populated the five users.
#
#   bin/rails runner plugins/discourse-notification-state-tracker/script/verify.rb
#
# When done, re-run the seed script if you want to do hands-on UI testing:
#   bin/rails runner plugins/discourse-notification-state-tracker/script/seed_test_scenarios.rb

raise "Refusing to run outside development" unless Rails.env.development?

def tags_for(user)
  TagUser
    .where(user_id: user.id)
    .pluck(:tag_id, :notification_level)
    .each_with_object({}) do |(tid, lvl), h|
      h[Tag.find(tid).name] = TagUser.notification_levels.key(lvl)
    end
end

def cats_for(user)
  CategoryUser
    .where(user_id: user.id)
    .pluck(:category_id, :notification_level)
    .each_with_object({}) do |(cid, lvl), h|
      h[Category.find(cid).name] = CategoryUser.notification_levels.key(lvl)
    end
end

def snap_count(user)
  DiscourseNotificationStateTracker::Snapshot.where(user_id: user.id).count
end

def report(label, user)
  printf "  %-7s tags=%-70s cats=%-30s snapshots=%d\n",
         label,
         tags_for(user).inspect,
         cats_for(user).inspect,
         snap_count(user)
end

scenarios = [
  {
    user: "nst_clean_join",
    desc: "no prior preferences → all reverted",
    steps: [{ remove_from: "team_engineering", expect_tags: {}, expect_cats: {} }],
  },
  {
    user: "nst_personal_pref",
    desc: "personal tracking/watching preserved (clean diff)",
    steps: [
      {
        remove_from: "team_engineering",
        expect_tags: {
          "engineering" => :tracking,
        },
        expect_cats: {
          "Team Announcements" => :watching,
        },
      },
    ],
  },
  {
    user: "nst_overlap",
    desc: "shared retained while still in team_design, then dropped",
    steps: [
      {
        remove_from: "team_engineering",
        expect_tags: {
          "shared" => :watching,
          "design" => :watching,
        },
        expect_cats: {
        },
      },
      { remove_from: "team_design", expect_tags: {}, expect_cats: {} },
    ],
  },
  {
    user: "nst_post_edit",
    desc: "post-join muted choice preserved (adversarial-review fix)",
    steps: [
      {
        remove_from: "team_engineering",
        expect_tags: {
          "engineering" => :muted,
        },
        expect_cats: {
        },
      },
    ],
  },
  {
    user: "nst_untracked_floor",
    desc: "untracked group's grant kept as floor",
    steps: [
      { remove_from: "team_engineering", expect_tags: { "shared" => :watching }, expect_cats: {} },
    ],
  },
]

passed = 0
failed = 0

scenarios.each do |s|
  user = User.find_by(username: s[:user])
  unless user
    puts "SKIP #{s[:user]} (user not found — did you run the seed script?)"
    failed += 1
    next
  end

  puts
  puts "▶ #{s[:user]}: #{s[:desc]}"
  report("BEFORE", user)

  s[:steps].each do |step|
    group = Group.find_by!(name: step[:remove_from])
    group.remove(user)
    puts "  ↳ removed from #{step[:remove_from]}"
    report("AFTER", user)

    actual_tags = tags_for(user)
    actual_cats = cats_for(user)
    if actual_tags == step[:expect_tags] && actual_cats == step[:expect_cats]
      puts "  ✓ matches expected"
      passed += 1
    else
      puts "  ✗ MISMATCH"
      puts "      expect_tags: #{step[:expect_tags].inspect}"
      puts "      expect_cats: #{step[:expect_cats].inspect}"
      failed += 1
    end
  end
end

puts
puts "=" * 50
puts "Result: #{passed} passed, #{failed} failed"
puts "=" * 50
