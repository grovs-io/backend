require "test_helper"

class GrovsFlagsTest < ActiveSupport::TestCase
  CF_KEYS = %w[CUSTOM_DOMAINS_ENABLED CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID CLOUDFLARE_SAAS_CNAME_TARGET MIGRATIONS_ENABLED].freeze

  def with_env(overrides)
    saved = CF_KEYS.index_with { |k| ENV[k] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def with_custom_domains_on(&block)
    with_env(
      "CUSTOM_DOMAINS_ENABLED" => "true",
      "CLOUDFLARE_API_TOKEN" => "t",
      "CLOUDFLARE_ZONE_ID" => "z",
      "CLOUDFLARE_SAAS_CNAME_TARGET" => "proxy.sqd.link",
      &block
    )
  end

  test "custom_domains_enabled? is false by default" do
    with_env("CUSTOM_DOMAINS_ENABLED" => nil) do
      assert_not Grovs.custom_domains_enabled?
    end
  end

  test "custom_domains_enabled? is true only when flag is 'true' and all three CF creds present" do
    with_env(
      "CUSTOM_DOMAINS_ENABLED" => "true",
      "CLOUDFLARE_API_TOKEN" => "t",
      "CLOUDFLARE_ZONE_ID" => "z",
      "CLOUDFLARE_SAAS_CNAME_TARGET" => "proxy.sqd.link"
    ) do
      assert Grovs.custom_domains_enabled?
    end
  end

  test "custom_domains_enabled? is false when flag is true but a CF cred is missing" do
    with_env(
      "CUSTOM_DOMAINS_ENABLED" => "true",
      "CLOUDFLARE_API_TOKEN" => nil,
      "CLOUDFLARE_ZONE_ID" => "z",
      "CLOUDFLARE_SAAS_CNAME_TARGET" => "proxy.sqd.link"
    ) do
      assert_not Grovs.custom_domains_enabled?
    end
  end

  test "custom_domains_enabled? is false when creds present but flag not exactly 'true'" do
    with_env(
      "CUSTOM_DOMAINS_ENABLED" => "1",
      "CLOUDFLARE_API_TOKEN" => "t",
      "CLOUDFLARE_ZONE_ID" => "z",
      "CLOUDFLARE_SAAS_CNAME_TARGET" => "proxy.sqd.link"
    ) do
      assert_not Grovs.custom_domains_enabled?
    end
  end

  # ---------------------------------------------------------------------------
  # migrations_enabled?
  # ---------------------------------------------------------------------------

  test "migrations_enabled? is false by default" do
    with_env("MIGRATIONS_ENABLED" => nil, "CUSTOM_DOMAINS_ENABLED" => nil) do
      assert_not Grovs.migrations_enabled?
    end
  end

  test "migrations_enabled? requires both its own flag AND custom_domains_enabled?" do
    with_custom_domains_on do
      with_env("MIGRATIONS_ENABLED" => "true") do
        assert Grovs.migrations_enabled?
      end
    end
  end

  test "migrations_enabled? is false when MIGRATIONS_ENABLED is on but custom domains is off" do
    with_env(
      "MIGRATIONS_ENABLED" => "true",
      "CUSTOM_DOMAINS_ENABLED" => nil
    ) do
      assert_not Grovs.migrations_enabled?
    end
  end

  test "migrations_enabled? is false when custom domains is on but MIGRATIONS_ENABLED is off" do
    with_custom_domains_on do
      with_env("MIGRATIONS_ENABLED" => nil) do
        assert_not Grovs.migrations_enabled?
      end
    end
  end

  test "migrations_enabled? is false when MIGRATIONS_ENABLED is not exactly 'true'" do
    with_custom_domains_on do
      with_env("MIGRATIONS_ENABLED" => "1") do
        assert_not Grovs.migrations_enabled?
      end
    end
  end
end
