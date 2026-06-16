require "test_helper"

class LinksServicePurposeTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames

  setup do
    enable_custom_domains!
    REDIS.flushdb
    @project = projects(:one)
    @domain  = domains(:one)

    CustomHostname.delete_all
    @primary = CustomHostname.create!(
      project: @project, domain: @domain,
      hostname: "new.acme.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_PRIMARY
    )
    @migration = CustomHostname.create!(
      project: @project, domain: @domain,
      hostname: "old-branch.acme.com", status: "active", source: "saas",
      purpose: Grovs::Hostnames::PURPOSE_MIGRATION
    )
  end

  teardown do
    disable_custom_domains!
  end

  test "custom_hostname_for resolves an active primary CustomHostname to the project Domain" do
    result = LinksService.custom_hostname_for("new.acme.com")
    assert_equal @domain.id, result&.id
  end

  test "custom_hostname_for resolves an active migration CustomHostname to the project Domain" do
    result = LinksService.custom_hostname_for("old-branch.acme.com")
    assert_equal @domain.id, result&.id
  end

  test "custom_hostname_for returns nil for a MAIN host" do
    assert_nil LinksService.custom_hostname_for("sqd.link")
    assert_nil LinksService.custom_hostname_for("anything.sqd.link")
  end

  test "custom_hostname_for returns nil when the feature flag is off" do
    Grovs.stub(:custom_domains_enabled?, false) do
      assert_nil LinksService.custom_hostname_for("new.acme.com")
      assert_nil LinksService.custom_hostname_for("old-branch.acme.com")
    end
  end

  test "primary_custom_hostname_for resolves an active primary CustomHostname to the project Domain" do
    result = LinksService.primary_custom_hostname_for("new.acme.com")
    assert_equal @domain.id, result&.id
  end

  test "primary_custom_hostname_for returns nil for an active migration CustomHostname" do
    assert_nil LinksService.primary_custom_hostname_for("old-branch.acme.com")
  end

  test "primary_custom_hostname_for returns nil when the matched CustomHostname is not resolvable" do
    @primary.update!(status: "pending")
    REDIS.with { |c| c.del("custom_hostnames:find_by:hostname:new.acme.com:no_includes") }

    assert_nil LinksService.primary_custom_hostname_for("new.acme.com")
  end

  test "primary_custom_hostname_for returns nil for a MAIN host" do
    assert_nil LinksService.primary_custom_hostname_for("sqd.link")
    assert_nil LinksService.primary_custom_hostname_for("anything.sqd.link")
  end

  test "primary_custom_hostname_for returns nil when the feature flag is off" do
    Grovs.stub(:custom_domains_enabled?, false) do
      assert_nil LinksService.primary_custom_hostname_for("new.acme.com")
      assert_nil LinksService.primary_custom_hostname_for("old-branch.acme.com")
    end
  end
end
