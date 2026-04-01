class CreateDevices < ActiveRecord::Migration[6.1]
  def change
    create_table :devices do |t|
      t.string :user_agent, null: false
      t.string :ip, null: false
      t.string :remote_ip , null: false
      t.string :cookie, null: false
      t.string :vendor
      t.integer :screen_width
      t.integer :screen_height
      t.float :screen_scale

      t.timestamps
    end
  end
end
