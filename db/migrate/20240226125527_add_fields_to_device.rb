class AddFieldsToDevice < ActiveRecord::Migration[6.1]
  def change
    add_column :devices, :platform, :string
    add_column :devices, :app_version, :string
    add_column :devices, :build, :string
    add_column :devices, :model, :string
  end
end
