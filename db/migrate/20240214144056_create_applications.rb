class CreateApplications < ActiveRecord::Migration[6.1]
  def change
    create_table :applications do |t|
      t.string :identifier, null: false
      t.belongs_to :project
      t.string :platform, null: false
      t.string :application_key, null: false

      t.timestamps
    end
  end
end
