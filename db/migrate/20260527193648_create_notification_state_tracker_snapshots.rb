# frozen_string_literal: true

class CreateNotificationStateTrackerSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :notification_state_tracker_snapshots do |t|
      t.integer :user_id, null: false
      t.integer :group_id, null: false
      t.string :notifiable_type, null: false # "Tag" or "Category"
      t.integer :notifiable_id, null: false
      # NULL is meaningful: the user had NO tag_users/category_users row before the
      # tracked group applied its defaults, so restoring means deleting the row.
      t.integer :notification_level, null: true
      t.timestamps
    end

    # Upsert conflict target + restore-by-membership lookup. Custom name because the
    # default Rails name would exceed PostgreSQL's 63-char identifier limit.
    add_index :notification_state_tracker_snapshots,
              %i[user_id group_id notifiable_type notifiable_id],
              unique: true,
              name: "idx_nst_snapshots_unique"

    # Baseline propagation lookup (find an existing snapshot for this user+notifiable
    # across any tracked group, so the true pre-group level is preserved).
    add_index :notification_state_tracker_snapshots,
              %i[user_id notifiable_type notifiable_id],
              name: "idx_nst_snapshots_baseline"
  end
end
