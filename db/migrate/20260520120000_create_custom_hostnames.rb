class CreateCustomHostnames < ActiveRecord::Migration[8.1]
  def change
    create_table :custom_hostnames do |t|
      t.bigint   :project_id, null: false
      t.bigint   :domain_id,  null: false
      t.string   :hostname,   null: false
      t.string   :cf_custom_hostname_id
      t.string   :status, null: false, default: "provisioning"
      t.string   :ssl_status
      t.text     :verification_errors
      t.string   :source, null: false, default: "saas"
      t.datetime :grace_until
      t.datetime :activated_at
      t.datetime :last_checked_at
      t.timestamps
    end

    add_index :custom_hostnames, :hostname, unique: true
    add_index :custom_hostnames, :project_id
    add_index :custom_hostnames, :domain_id
    add_index :custom_hostnames, :cf_custom_hostname_id
    add_index :custom_hostnames, :status
  end
end
