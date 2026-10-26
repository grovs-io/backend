require "test_helper"
require Rails.root.join("db/migrate/20261006120000_add_in_app_browser_page_to_redirect_configs")

class AddInAppBrowserPageToRedirectConfigsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  COLUMNS = %w[in_app_browser_page_ios in_app_browser_page_android].freeze

  setup do
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:iab_mig_probe, force: true) { |t| t.bigint :project_id }
    @conn.execute("INSERT INTO iab_mig_probe (project_id) VALUES (1)")
    @migration = AddInAppBrowserPageToRedirectConfigs.new
    @migration.verbose = false
  end

  teardown { @conn.drop_table(:iab_mig_probe, if_exists: true) }

  test "existing rows get false, new rows get true, rollback removes the columns" do
    with_table(:iab_mig_probe) { @migration.migrate(:up) }

    assert_equal [false, false], @conn.select_rows("SELECT #{COLUMNS.join(', ')} FROM iab_mig_probe WHERE project_id = 1").first
    @conn.execute("INSERT INTO iab_mig_probe (project_id) VALUES (2)")
    assert_equal [true, true], @conn.select_rows("SELECT #{COLUMNS.join(', ')} FROM iab_mig_probe WHERE project_id = 2").first
    COLUMNS.each { |c| assert_not @conn.columns(:iab_mig_probe).find { |col| col.name == c }.null }

    with_table(:iab_mig_probe) { @migration.migrate(:down) }
    assert_empty COLUMNS & @conn.columns(:iab_mig_probe).map(&:name)
  end

  private

  def with_table(name)
    original = AddInAppBrowserPageToRedirectConfigs::TABLE
    AddInAppBrowserPageToRedirectConfigs.send(:remove_const, :TABLE)
    AddInAppBrowserPageToRedirectConfigs.const_set(:TABLE, name)
    yield
  ensure
    AddInAppBrowserPageToRedirectConfigs.send(:remove_const, :TABLE)
    AddInAppBrowserPageToRedirectConfigs.const_set(:TABLE, original)
  end
end
