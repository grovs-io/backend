class CreateSetupProgressSteps < ActiveRecord::Migration[7.0]
  def change
    create_table :setup_progress_steps do |t|
      t.bigint :instance_id, null: false
      t.string :category, null: false
      t.string :step_identifier, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :setup_progress_steps, [:instance_id, :category, :step_identifier], unique: true, name: 'idx_setup_progress_unique'
    add_index :setup_progress_steps, [:instance_id, :category], name: 'idx_setup_progress_instance_category'
    add_foreign_key :setup_progress_steps, :instances
  end
end
