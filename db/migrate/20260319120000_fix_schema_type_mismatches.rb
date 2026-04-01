class FixSchemaTypeMismatches < ActiveRecord::Migration[7.0]
  def up
    column = columns(:stripe_subscriptions).find { |c| c.name == "cancels_at" }
    return if column.nil? || column.sql_type.start_with?("timestamp")

    # Existing time-only values have no date component — flag rows for backfill from Stripe
    unless column_exists?(:stripe_subscriptions, :cancels_at_needs_backfill)
      add_column :stripe_subscriptions, :cancels_at_needs_backfill, :boolean, default: false
    end
    execute <<~SQL
      UPDATE stripe_subscriptions SET cancels_at_needs_backfill = true WHERE cancels_at IS NOT NULL
    SQL

    remove_column :stripe_subscriptions, :cancels_at
    add_column :stripe_subscriptions, :cancels_at, :datetime
  end

  def down
    if column_exists?(:stripe_subscriptions, :cancels_at_needs_backfill)
      remove_column :stripe_subscriptions, :cancels_at_needs_backfill
    end
    remove_column :stripe_subscriptions, :cancels_at
    add_column :stripe_subscriptions, :cancels_at, :time
  end
end
