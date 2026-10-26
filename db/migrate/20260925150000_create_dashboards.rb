class CreateDashboards < ActiveRecord::Migration[8.1]
  def change
    create_table :dashboards do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :dashboards, %i[project_id position]

    create_table :dashboard_widgets do |t|
      t.references :dashboard, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :title, null: false
      t.string :viz, null: false, default: 'bar'
      t.string :size, null: false, default: 'md'
      t.jsonb :query, null: false, default: {}
      t.jsonb :filters, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :dashboard_widgets, %i[dashboard_id position]
  end
end
