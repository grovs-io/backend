class AddWebSdkLastSeenAtToProjects < ActiveRecord::Migration[8.1]
  # projects is high-write; grab the lock in a short window and retry instead of blocking writes.
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"
  MAX_LOCK_RETRIES = 5
  RETRY_PAUSE = 10.seconds

  def up
    with_lock_timeout_retries do
      add_column :projects, :web_sdk_last_seen_at, :datetime, if_not_exists: true
    end
  end

  def down
    remove_column :projects, :web_sdk_last_seen_at, if_exists: true
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
