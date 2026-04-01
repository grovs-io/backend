class CreateEnterpriseSubscriptions < ActiveRecord::Migration[7.0]
  def change
    create_table :enterprise_subscriptions do |t|
      t.datetime :start_date
      t.datetime :end_date
      t.integer :total_maus
      t.boolean :active, default: true
      t.integer :instance_id, null: false # Optional field

      t.timestamps
    end

    # Adding foreign key constraint for instance_id, but it's optional
    add_index :enterprise_subscriptions, :instance_id
  end
end
