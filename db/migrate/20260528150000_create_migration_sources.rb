class CreateMigrationSources < ActiveRecord::Migration[8.1]
  def change
    create_table :migration_sources do |t|
      # MVP: one migration source per project (mirrors custom_hostnames.project_id unique index).
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string  :old_host, null: false
      t.string  :provider, null: false                                 # branch | appsflyer | adjust | singular
      t.text    :credentials                                           # encrypts :credentials at the model layer — stored as ciphertext text

      t.boolean :enabled, null: false, default: true
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :first_failure_at
      t.integer  :last_error_status                                    # last upstream HTTP code on failure
      t.datetime :degraded_email_sent_at                               # idempotency marker for the 1h escalation email
      # Set when disable_with_notification! flips enabled→false (auto-disable). Stays nil
      # when an admin explicitly PATCHes enabled=false. Lets us:
      #   - Auto-re-enable on credentials PATCH ONLY if auto_disabled_at is set
      #     (admin's explicit disable is preserved through credential rotations)
      #   - Serve project_defaults for cache-miss clicks under auto-disable (mailer promises
      #     this fallback)
      t.datetime :auto_disabled_at
      t.timestamps
    end

    # One source globally owns a given host (no two projects can claim the same migration host).
    add_index :migration_sources, :old_host, unique: true

    # DB-level enforcement of the provider enum. Mirrors MVP_PROVIDERS exactly — adding a new
    # adapter (adjust, singular, etc.) requires a follow-up migration to loosen the check
    # alongside the client/constant/validator changes. Forces all four layers (constraint,
    # constant, validator, dispatcher) to stay in sync.
    add_check_constraint :migration_sources,
      "provider IN ('branch','appsflyer')",
      name: "migration_sources_provider_check"
  end
end
