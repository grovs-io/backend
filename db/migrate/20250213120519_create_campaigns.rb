class CreateCampaigns < ActiveRecord::Migration[7.0]
  def change
    create_table :campaigns do |t|
      t.string :name
      t.references :project, null: false, foreign_key: true
      t.boolean :archived, default: false

      t.timestamps
    end
  end
end
