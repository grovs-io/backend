class CreateNotificationMessages < ActiveRecord::Migration[7.0]
  def change
    create_table :notification_messages do |t|
      t.references :notification, null: false, foreign_key: true
      t.references :visitor, null: false, foreign_key: true
      t.boolean :read, default: false
      
      t.timestamps
    end
  end
end
