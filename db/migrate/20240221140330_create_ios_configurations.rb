class CreateIosConfigurations < ActiveRecord::Migration[6.1]
  def change
    create_table :ios_configurations do |t|
      t.string :bundle_id, null: false
      t.string :uri_scheme, null: false
      t.string :app_prefix , null: false
      
      t.timestamps
    end
  end
end
