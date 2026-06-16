require "test_helper"

class MigrationProviderClientTest < ActiveSupport::TestCase
  include MigrationFixtureHelpers

  fixtures :projects, :instances, :domains, :redirect_configs, :custom_hostnames, :migration_sources

  setup do
    reset_acme_active_to_active!

    @source = migration_sources(:acme_branch)
    @source.update!(credentials: { "branch_key" => "key_live_test" })
  end

  test "branch source returns BranchMigrationClient" do
    client = MigrationProviderClient.for(@source)
    assert_instance_of BranchMigrationClient, client
  end

  test "appsflyer source returns AppsflyerMigrationClient" do
    @source.update!(provider: "appsflyer", credentials: { "onelink_id" => "abc", "api_token" => "tok" })
    client = MigrationProviderClient.for(@source)
    assert_instance_of AppsflyerMigrationClient, client
  end

  test "unknown provider raises ArgumentError" do
    @source.stub(:provider, "weirdprovider") do
      err = assert_raises(ArgumentError) { MigrationProviderClient.for(@source) }
      assert_match(/Unknown migration provider/, err.message)
    end
  end

  test "DB CHECK constraint blocks adjust / singular at the data layer" do
    %w[adjust singular].each do |unsupported|
      assert_raises(ActiveRecord::StatementInvalid) do
        @source.update_columns(provider: unsupported)
      end
    end
  end
end
