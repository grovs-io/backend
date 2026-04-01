class CreateLinks < ActiveRecord::Migration[6.1]
  def change
    create_table :links do |t|
      t.belongs_to :redirect_config, null: false
      
      t.string :title
      t.string :subtitle
      t.string :path, null: false

      t.timestamps
    end
  end
end
