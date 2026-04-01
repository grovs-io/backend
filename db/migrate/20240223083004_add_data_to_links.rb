class AddDataToLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :data, :json, default: nil
  end
end
