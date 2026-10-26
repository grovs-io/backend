require "test_helper"

class GrovsFlagsTest < ActiveSupport::TestCase
  CF_KEYS = %w[CUSTOM_DOMAINS_ENABLED CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID CLOUDFLARE_SAAS_CNAME_TARGET MIGRATIONS_ENABLED GROVS_SELF_HOSTED 
CUSTOM_DOMAINS_PROVIDER MAILER_DELIVERY_METHOD].freeze

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

  test "manual_custom_domains? is false by default" do
    with_env("CUSTOM_DOMAINS_PROVIDER" => nil) do
      assert_not Grovs.manual_custom_domains?
    end
  end

  test "manual_custom_domains? is true only when the provider is exactly 'manual'" do
    with_env("CUSTOM_DOMAINS_PROVIDER" => "manual") do
      assert Grovs.manual_custom_domains?
    end
    with_env("CUSTOM_DOMAINS_PROVIDER" => "cloudflare") do
      assert_not Grovs.manual_custom_domains?
    end
    with_env("CUSTOM_DOMAINS_PROVIDER" => "Manual") do
      assert_not Grovs.manual_custom_domains?
    end
  end

  test "manual provider wins even when Cloudflare creds are present" do
    with_custom_domains_on do
      with_env("CUSTOM_DOMAINS_PROVIDER" => "manual") do
        assert Grovs.manual_custom_domains?
      end
    end
  end

  test "custom_domains_enabled? is true with the flag and provider manual, no Cloudflare" do
    with_env("CUSTOM_DOMAINS_ENABLED" => "true", "CUSTOM_DOMAINS_PROVIDER" => "manual",
             "CLOUDFLARE_API_TOKEN" => nil, "CLOUDFLARE_ZONE_ID" => nil,
             "CLOUDFLARE_SAAS_CNAME_TARGET" => nil) do
      assert Grovs.custom_domains_enabled?
    end
  end

  test "custom_domains_enabled? still requires its own flag with provider manual" do
    with_env("CUSTOM_DOMAINS_ENABLED" => nil, "CUSTOM_DOMAINS_PROVIDER" => "manual",
             "CLOUDFLARE_API_TOKEN" => nil, "CLOUDFLARE_ZONE_ID" => nil,
             "CLOUDFLARE_SAAS_CNAME_TARGET" => nil) do
      assert_not Grovs.custom_domains_enabled?
    end
  end

  test "an unknown provider value falls back to requiring Cloudflare creds" do
    with_env("CUSTOM_DOMAINS_ENABLED" => "true", "CUSTOM_DOMAINS_PROVIDER" => "manuel",
             "CLOUDFLARE_API_TOKEN" => nil, "CLOUDFLARE_ZONE_ID" => nil,
             "CLOUDFLARE_SAAS_CNAME_TARGET" => nil) do
      assert_not Grovs.custom_domains_enabled?
    end
  end

  test "migrations_enabled? turns on with provider manual, no Cloudflare" do
    with_env("CUSTOM_DOMAINS_ENABLED" => "true", "CUSTOM_DOMAINS_PROVIDER" => "manual",
             "MIGRATIONS_ENABLED" => "true", "CLOUDFLARE_API_TOKEN" => nil,
             "CLOUDFLARE_ZONE_ID" => nil, "CLOUDFLARE_SAAS_CNAME_TARGET" => nil) do
      assert Grovs.migrations_enabled?
    end
  end

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

  test "smtp_enabled? is true only when MAILER_DELIVERY_METHOD is exactly 'smtp'" do
    with_env("MAILER_DELIVERY_METHOD" => "smtp") do
      assert Grovs.smtp_enabled?
    end
    with_env("MAILER_DELIVERY_METHOD" => nil) do
      assert_not Grovs.smtp_enabled?
    end
    with_env("MAILER_DELIVERY_METHOD" => "sendgrid") do
      assert_not Grovs.smtp_enabled?
    end
  end

  IN_APP_PREVIEW_KEYS = %w[IN_APP_PREVIEW_ORIGINS REACT_HOST_PROTOCOL REACT_HOST REACT_BETA_HOST_PROTOCOL REACT_BETA_HOST].freeze

  def with_preview_env(overrides, &block)
    saved = IN_APP_PREVIEW_KEYS.index_with { |k| ENV[k] }
    overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "in_app_preview_origins defaults to the react host and the beta host, each with its protocol" do
    with_preview_env("IN_APP_PREVIEW_ORIGINS" => nil, "REACT_HOST_PROTOCOL" => "http://", "REACT_HOST" => "localhost:3001",
                      "REACT_BETA_HOST_PROTOCOL" => "https://", "REACT_BETA_HOST" => "beta.example.com") do
      assert_equal ["http://localhost:3001", "https://beta.example.com"], Grovs.in_app_preview_origins
    end
  end

  test "in_app_preview_origins strips a trailing slash and defaults a blank protocol to https" do
    with_preview_env("IN_APP_PREVIEW_ORIGINS" => nil, "REACT_HOST_PROTOCOL" => nil, "REACT_HOST" => "app.grovs.io/",
                      "REACT_BETA_HOST_PROTOCOL" => nil, "REACT_BETA_HOST" => nil) do
      assert_equal ["https://app.grovs.io"], Grovs.in_app_preview_origins
    end
  end

  test "IN_APP_PREVIEW_ORIGINS fully replaces the default list, comma-separated and trimmed" do
    with_preview_env("IN_APP_PREVIEW_ORIGINS" => " https://dash.example.com , https://dash2.example.com ",
                      "REACT_HOST" => "localhost:3001", "REACT_BETA_HOST" => "beta.example.com") do
      assert_equal ["https://dash.example.com", "https://dash2.example.com"], Grovs.in_app_preview_origins
    end
  end

  test "IN_APP_PREVIEW_ORIGINS strips a trailing slash from each entry" do
    with_preview_env("IN_APP_PREVIEW_ORIGINS" => "https://dash.example.com/, https://dash2.example.com//") do
      assert_equal ["https://dash.example.com", "https://dash2.example.com"], Grovs.in_app_preview_origins
    end
  end

  test "in_app_preview_origins is empty when nothing is configured" do
    with_preview_env("IN_APP_PREVIEW_ORIGINS" => nil, "REACT_HOST_PROTOCOL" => nil, "REACT_HOST" => nil,
                      "REACT_BETA_HOST_PROTOCOL" => nil, "REACT_BETA_HOST" => nil) do
      assert_equal [], Grovs.in_app_preview_origins
    end
  end
end
