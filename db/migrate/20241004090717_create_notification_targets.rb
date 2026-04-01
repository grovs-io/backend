class CreateNotificationTargets < ActiveRecord::Migration[7.0]
  def change
    create_table :notification_targets do |t|
      t.references :notification, null: false, foreign_key: true
      t.boolean :existing_users, default: false
      t.boolean :new_users, default: false
      t.string :platforms, array: true, default: []
      
      t.timestamps
    end
  end
end
