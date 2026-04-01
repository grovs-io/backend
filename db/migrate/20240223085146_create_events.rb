class CreateEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :events do |t|
      t.belongs_to :project, null: false
      t.belongs_to :device, null: false

      t.belongs_to :link

      t.string :type, null: false
      t.json :data

      t.timestamps
    end
  end
end
