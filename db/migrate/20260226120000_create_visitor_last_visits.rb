class CreateVisitorLastVisits < ActiveRecord::Migration[7.0]
  def change
    unless table_exists?(:visitor_last_visits)
      create_table :visitor_last_visits do |t|
        t.references :project, null: false, foreign_key: true
        t.references :visitor, null: false, foreign_key: true
        t.references :link, foreign_key: true

        t.timestamps
      end
    end

    unless index_exists?(:visitor_last_visits, [:project_id, :visitor_id], name: "index_vlv_on_project_and_visitor")
      add_index :visitor_last_visits, [:project_id, :visitor_id],
                unique: true,
                name: "index_vlv_on_project_and_visitor"
    end
  end
end
