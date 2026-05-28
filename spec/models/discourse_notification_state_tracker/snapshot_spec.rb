# frozen_string_literal: true

RSpec.describe DiscourseNotificationStateTracker::Snapshot do
  fab!(:user)
  fab!(:group)
  fab!(:other_group, :group)
  fab!(:tag)

  it "scopes rows to a single user/group membership" do
    mine =
      described_class.create!(
        user: user,
        group: group,
        notifiable_type: "Tag",
        notifiable_id: tag.id,
        notification_level: TagUser.notification_levels[:tracking],
      )
    described_class.create!(
      user: user,
      group: other_group,
      notifiable_type: "Tag",
      notifiable_id: tag.id,
      notification_level: nil,
    )

    expect(described_class.for_membership(user, group)).to contain_exactly(mine)
  end

  it "allows a NULL notification_level to record an absent prior preference" do
    snapshot =
      described_class.create!(
        user: user,
        group: group,
        notifiable_type: "Category",
        notifiable_id: 1,
        notification_level: nil,
      )

    expect(snapshot.reload.notification_level).to be_nil
  end
end
