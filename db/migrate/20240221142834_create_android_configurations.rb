class CreateAndroidConfigurations < ActiveRecord::Migration[6.1]
  def change
    create_table :android_configurations do |t|
      t.string :identifier, null: false
      t.string :uri_scheme, null: false
      t.string :sha , null: false
      
      t.belongs_to :application

      t.timestamps
    end
  end
end
