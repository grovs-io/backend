class CreateAndroidPushConfigurations < ActiveRecord::Migration[7.0]
  def change
    create_table :android_push_configurations do |t|
      t.references :android_configuration, null: false, foreign_key: true
      t.string :name
      t.string :firebase_project_id
      t.timestamps
    end
  end
end
