class AddInAppBrowserPageToRedirectConfigs < ActiveRecord::Migration[8.1]
  # redirect_configs is read on every redirect; grab the lock in a short window and retry instead of blocking.
  disable_ddl_transaction!

  TABLE = :redirect_configs
  COLUMNS = %i[in_app_browser_page_ios in_app_browser_page_android].freeze
  LOCK_TIMEOUT = "5s"
  MAX_LOCK_RETRIES = 5
  RETRY_PAUSE = 10.seconds

  def up
    COLUMNS.each do |column|
      # Existing projects keep today's behaviour; only projects created afterwards default on.
      with_lock_timeout_retries { add_column TABLE, column, :boolean, null: false, default: false, if_not_exists: true }
      with_lock_timeout_retries { change_column_default TABLE, column, true }
    end
  end

  def down
    COLUMNS.each do |column|
      with_lock_timeout_retries { remove_column TABLE, column, if_exists: true }
    end
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
