class CreateActions < ActiveRecord::Migration[6.1]
  def change
    create_table :actions do |t|
      t.belongs_to :device, null: false
      t.belongs_to :link, null: false

      t.timestamps
    end
  end
end
