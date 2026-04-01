class CreateDiagnosticsLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :diagnostics_logs do |t|
      t.string :test_key, null: false
      t.string :operation, null: false
      t.text :payload
      t.string :hostname
      t.float :duration_ms

      t.timestamps
    end

    add_index :diagnostics_logs, :test_key
    add_index :diagnostics_logs, :created_at
  end
end
