class CreateSmartBanners < ActiveRecord::Migration[8.1]
  # smart_banners is new, but its project_id FK locks the existing, high-write projects
  # table briefly to add — retry in a short window instead of parking the request.
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"
  MAX_LOCK_RETRIES = 5
  RETRY_PAUSE = 10.seconds

  def up
    with_lock_timeout_retries do
      create_table :smart_banners, if_not_exists: true do |t|
        t.references :project, null: false, foreign_key: true, index: false
        t.references :default_link, foreign_key: { to_table: :links, validate: false }
        t.string :name, null: false
        t.boolean :active, null: false, default: true
        t.integer :priority, null: false, default: 0
        t.string :platforms, array: true, null: false, default: %w[ios android]
        t.string :url_include, array: true, null: false, default: []
        t.string :url_exclude, array: true, null: false, default: []
        t.string :position, null: false, default: "top"
        t.string :title, null: false
        t.string :subtitle
        t.string :button_text, null: false, default: "Open"
        t.string :background_color, null: false, default: "#FFFFFF"
        t.string :text_color, null: false, default: "#111827"
        t.string :button_color, null: false, default: "#4F46E5"
        t.string :button_text_color, null: false, default: "#FFFFFF"
        t.integer :dismiss_days, null: false, default: 7
        t.timestamps
      end
      add_index :smart_banners, [:project_id, :priority], if_not_exists: true
    end

    with_lock_timeout_retries do
      create_table :smart_banner_links, if_not_exists: true do |t|
        t.references :smart_banner, null: false, foreign_key: true, index: false
        t.string :data_hash, null: false
        t.references :link, null: false, foreign_key: { validate: false }
        t.timestamps
      end
      add_index :smart_banner_links, [:smart_banner_id, :data_hash], unique: true, if_not_exists: true
    end
  end

  def down
    drop_table :smart_banner_links, if_exists: true
    drop_table :smart_banners, if_exists: true
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
