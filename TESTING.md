# Manual testing guide

## Scripts

The plugin ships two runner scripts under `script/`. Run them from the Discourse
repo root.

**Seed the test scenarios** — creates the tracked groups (`team_engineering`,
`team_design`), the untracked group (`external_contractors`), the
`engineering` / `design` / `shared` tags, the `Team Announcements` category,
five scenario users (`nst_clean_join`, `nst_personal_pref`, `nst_overlap`,
`nst_post_edit`, `nst_untracked_floor`), and an admin (`nst_admin`). All users
share the password `Testpass1234!`. The script is idempotent — re-run it any
time to reset the five users back to their BEFORE state without touching the
rest of the dev DB:

```bash
bin/rails runner plugins/discourse-notification-state-tracker/script/seed_test_scenarios.rb
```

**Verify all scenarios automatically** — performs the group removals for each
seeded user, prints BEFORE/AFTER, and asserts the EXPECTED result. Leaves the
dev DB in the AFTER state; re-run the seed above to restore BEFORE state for
hands-on UI testing:

```bash
bin/rails runner plugins/discourse-notification-state-tracker/script/verify.rb
```

For UI testing, run the seed and then sign in as `nst_admin` / `Testpass1234!`
and walk through the scenarios below.

## Groups and tags it created

- **Tracked**: `team_engineering` (watches `engineering`, `shared`, and the
  `Team Announcements` category), `team_design` (watches `design`, `shared`).
- **Untracked**: `external_contractors` (watches `shared`).

## Scenarios

For each one: confirm the **BEFORE** state in the user's
`/u/<username>/preferences/tags` and `/u/<username>/preferences/categories`,
then perform the **ACTION** in `/admin/groups/<group>/members` (the "Remove"
button next to the user), and confirm the **EXPECTED AFTER** state.

### 1) `nst_clean_join` — no prior preferences

- **BEFORE**: in `team_engineering`; watches `engineering` + `shared` +
  `Team Announcements`. Has a snapshot row per affected tag/category (NULL baseline).
- **ACTION**: remove from `team_engineering`.
- **EXPECTED**: no tags watched, no category watched, snapshots for that membership
  gone.

### 2) `nst_personal_pref` — preference predates the group ("don't change his watching")

- **BEFORE**: personally has `engineering` at *tracking* and `Team Announcements`
  at *watching*; now in `team_engineering`, which raised `engineering` to
  *watching* (semantic-higher merge) and kept `Team Announcements` at *watching*.
  Snapshot rows record the prior `tracking` / `watching` baselines.
- **ACTION**: remove from `team_engineering`.
- **EXPECTED**: `engineering` reverts to *tracking* (their personal level);
  `Team Announcements` stays at *watching*. `shared` (no prior, group-added)
  is removed.

### 3) `nst_overlap` — same tag granted by two tracked groups

- **BEFORE**: in `team_engineering` and `team_design`. Watches all three team tags;
  `shared` comes from both groups. Two snapshot rows per team tag (one per
  group), both NULL baseline (propagated).
- **ACTION (a)**: remove from `team_engineering` only.
- **EXPECTED (a)**: `shared` and `design` still watched (team_design still
  grants them); `engineering` removed. `team_engineering`'s snapshot rows gone;
  `team_design`'s remain.
- **ACTION (b)**: now remove from `team_design` too.
- **EXPECTED (b)**: all team tags removed; no snapshots left for this user.

### 4) `nst_post_edit` — user manually muted the tag after joining

- **BEFORE**: in `team_engineering`; group set `engineering` to *watching*,
  then the user changed it to *muted*. (`shared` and `Team Announcements` are
  still at the group-derived levels.)
- **ACTION**: remove from `team_engineering`.
- **EXPECTED**: `engineering` **stays muted** (the user's explicit later
  choice is preserved — not reverted, not deleted). `shared` and
  `Team Announcements` are removed.

### 5) `nst_untracked_floor` — joined an untracked group after the tracked one

- **BEFORE**: in `team_engineering` (tracked) and `external_contractors` (untracked).
  Watches `engineering`, `shared` (granted by both), and `Team Announcements`.
  Snapshots exist only for the tracked group.
- **ACTION**: remove from `team_engineering`.
- **EXPECTED**: `engineering` removed, `Team Announcements` removed, but
  `shared` **stays watched** because `external_contractors` still grants it.

## Inspecting state from the console

If you'd rather look at the data directly:

```ruby
# bin/rails c
u = User.find_by(username: "nst_personal_pref")
TagUser.where(user_id: u.id).map { |t| [Tag.find(t.tag_id).name, TagUser.notification_levels.key(t.notification_level)] }
CategoryUser.where(user_id: u.id).map { |c| [Category.find(c.category_id).name, CategoryUser.notification_levels.key(c.notification_level)] }
DiscourseNotificationStateTracker::Snapshot.where(user_id: u.id).each { |s| puts "#{Group.find(s.group_id).name}/#{s.notifiable_type}/#{s.notifiable_id} baseline=#{s.notification_level || 'NULL'}" }
```
