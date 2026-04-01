class AddIsTestProjectFlag < ActiveRecord::Migration[6.1]
  def change
    add_column :projects, :test, :boolean, default: false
  end
end
