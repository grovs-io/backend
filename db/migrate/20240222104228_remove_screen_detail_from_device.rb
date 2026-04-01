class RemoveScreenDetailFromDevice < ActiveRecord::Migration[6.1]
  def change
    remove_column :devices, :screen_width
    remove_column :devices, :screen_height
    remove_column :devices, :screen_scale
  end
end
