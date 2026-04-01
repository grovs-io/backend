class AddDataToDevices < ActiveRecord::Migration[7.0]
  def change
    add_column :devices, :screen_width, :integer
    add_column :devices, :screen_height, :integer
    add_column :devices, :timezone, :string
    add_column :devices, :webgl_vendor, :string
    add_column :devices, :webgl_renderer, :string
  end
end
