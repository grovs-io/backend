class CreateDesktopConfigurations < ActiveRecord::Migration[6.1]
  def change
    create_table :desktop_configurations do |t|
      t.belongs_to :application
      
      t.timestamps
    end
  end
end
