class CreateFailedPurchaseJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :failed_purchase_jobs do |t|
      t.string   :job_class,        null: false
      t.jsonb    :arguments,         null: false, default: []
      t.string   :error_class
      t.text     :error_message
      t.text     :backtrace
      t.bigint   :purchase_event_id
      t.bigint   :project_id
      t.string   :status,           null: false, default: 'pending'
      t.datetime :failed_at,        null: false
      t.datetime :retried_at
      t.timestamps
    end

    add_index :failed_purchase_jobs, :status
    add_index :failed_purchase_jobs, :purchase_event_id
    add_index :failed_purchase_jobs, :project_id
  end
end
