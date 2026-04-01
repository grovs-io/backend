class CreateWebConfigurations < ActiveRecord::Migration[6.1]
  def change
    create_table :web_configurations do |t|
      t.belongs_to :application
  
      t.timestamps
    end
  end
end
