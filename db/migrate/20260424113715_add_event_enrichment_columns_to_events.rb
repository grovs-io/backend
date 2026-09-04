class AddEventEnrichmentColumnsToEvents < ActiveRecord::Migration[8.1]
  # events is high-write: grab the lock in a short window and retry instead of parking an
  # ACCESS EXCLUSIVE request that blocks all writes. No DDL transaction so a timed-out ALTER
  # doesn't poison a transaction and each retry is clean. Columns use constant defaults
  # (metadata-only on PG 11+, no rewrite) and if_not_exists (rerun-safe across retries).
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"
  MAX_LOCK_RETRIES = 5
  RETRY_PAUSE = 10.seconds

  def up
    with_lock_timeout_retries do
      add_column :events, :event_name, :string, default: "", null: false, if_not_exists: true
      add_column :events, :session_id, :string, default: "", null: false, if_not_exists: true
      add_column :events, :tags, :string, array: true, default: [], null: false, if_not_exists: true
    end
  end

  def down
    remove_column :events, :event_name, if_exists: true
    remove_column :events, :session_id, if_exists: true
    remove_column :events, :tags, if_exists: true
  end

  private

  def with_lock_timeout_retries
    attempt = 0
    begin
      execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
      yield
    rescue ActiveRecord::LockWaitTimeout
      attempt += 1
      raise if attempt > MAX_LOCK_RETRIES

      Rails.logger.warn("#{self.class.name}: lock busy, retry #{attempt}/#{MAX_LOCK_RETRIES} in #{RETRY_PAUSE.to_i}s")
      sleep RETRY_PAUSE
      retry
    ensure
      execute "SET lock_timeout = DEFAULT"
    end
  end
end
