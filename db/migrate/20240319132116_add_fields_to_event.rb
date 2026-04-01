class AddFieldsToEvent < ActiveRecord::Migration[6.1]
  def change
    add_column :events, :path, :string
    add_column :events, :ip, :string
    add_column :events, :remote_ip, :string
    add_column :events, :vendor_id, :string
    add_column :events, :platform, :string
    add_column :events, :app_version, :string
    add_column :events, :build, :string
  end
end
