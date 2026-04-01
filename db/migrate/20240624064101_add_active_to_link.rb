class AddActiveToLink < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :active, :boolean, default: true
  end
end
