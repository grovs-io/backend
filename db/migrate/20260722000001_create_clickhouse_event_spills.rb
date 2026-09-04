class CreateClickhouseEventSpills < ActiveRecord::Migration[8.1]
  def change
    create_table :clickhouse_event_spills do |t|
      t.string   :event_id, null: false
      t.jsonb    :ch_row, null: false
      t.bigint   :project_id, null: false
      t.datetime :event_created_at, null: false
      t.datetime :spilled_at, null: false
      t.integer  :attempts, null: false, default: 0
      t.text     :last_error
    end
    add_index :clickhouse_event_spills, :event_id, unique: true
    add_index :clickhouse_event_spills, [:spilled_at, :id], where: "attempts < 10",
                                                            name: "index_ch_event_spills_drainable"
    add_index :clickhouse_event_spills, [:project_id, :event_created_at]
  end
end
