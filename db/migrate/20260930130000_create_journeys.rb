class CreateJourneys < ActiveRecord::Migration[8.1]
  def up
    create_table :journeys do |t|
      t.references :project, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :status, null: false, default: "draft"
      t.jsonb :entry, null: false, default: {}
      t.jsonb :re_entry, null: false, default: { "mode" => "once", "days" => nil }
      t.jsonb :goals, null: false, default: []
      t.integer :control_group
      t.datetime :start_at
      t.datetime :end_at
      t.string :first_step
      t.jsonb :steps, null: false, default: {}
      t.jsonb :segment_keys, null: false, default: {}
      t.integer :revision, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.datetime :launched_at
      t.datetime :ended_at
      t.datetime :finished_at
      t.string :failure_reason
      t.timestamps
    end
    add_index :journeys, :status, where: "status IN ('live', 'paused', 'ended')", name: "index_journeys_running"

    create_table :journey_people do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.references :journey, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :person_key, null: false
      t.bigint :visitor_id, null: false
      t.string :step_id
      t.datetime :due_at
      t.string :until_event
      t.boolean :until_hit, null: false, default: false
      t.boolean :goal_hit, null: false, default: false
      t.string :state, null: false, default: "active"
      t.datetime :entered_at, null: false
      t.datetime :left_at
      t.string :left_reason
      t.datetime :claimed_at
    end
    add_index :journey_people, %i[journey_id person_key], unique: true
    add_index :journey_people, %i[journey_id due_at], where: "state = 'active'", name: "index_journey_people_due"
    add_index :journey_people, %i[journey_id until_event], where: "state = 'active' AND until_event IS NOT NULL",
                                                           name: "index_journey_people_until"
    add_index :journey_people, %i[journey_id claimed_at], where: "state = 'claimed'", name: "index_journey_people_claimed"
    # Every move rewrites the row: room on the page keeps updates HOT, and vacuum keeps up with the churn.
    execute "ALTER TABLE journey_people SET (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.02, " \
            "autovacuum_analyze_scale_factor = 0.05, autovacuum_vacuum_cost_delay = 2)"

    create_table :journey_counts do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.references :journey, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :step_id, null: false
      t.string :branch, null: false
      t.date :day, null: false
      t.bigint :people, null: false, default: 0
    end
    add_index :journey_counts, %i[journey_id step_id branch day], unique: true, name: "index_journey_counts_unique"
  end

  def down
    drop_table :journey_counts
    drop_table :journey_people
    drop_table :journeys
  end
end
