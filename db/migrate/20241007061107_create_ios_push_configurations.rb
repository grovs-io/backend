class CreateIosPushConfigurations < ActiveRecord::Migration[7.0]
  def change
    create_table :ios_push_configurations do |t|
      t.references :ios_configuration, null: false, foreign_key: true
      t.string :name
      t.string :certificate_password
      t.timestamps
    end
  end
end
