class CreateQuickLinks < ActiveRecord::Migration[6.1]
  def change
    create_table :quick_links do |t|
      t.belongs_to :domain, null: false
      t.string :fallback, null: false

      t.string :ios_phone
      t.string :ios_tablet

      t.string :android_phone
      t.string :android_tablet

      t.string :desktop_mac
      t.string :desktop_windows

      t.timestamps
    end
  end
end
