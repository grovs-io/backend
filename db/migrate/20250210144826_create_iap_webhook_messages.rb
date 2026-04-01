class CreateIapWebhookMessages < ActiveRecord::Migration[7.0]
  def change
    create_table :iap_webhook_messages do |t|
      t.text :payload, null: false
      t.string :source, null: false # 'apple' or 'google'
      t.string :type
      t.references :project, foreign_key: true
      t.timestamps
    end
  end
end
