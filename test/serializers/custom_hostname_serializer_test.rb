require "test_helper"

class CustomHostnameSerializerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames

  setup do
    REDIS.flushdb
    @saved_server_host = ENV["SERVER_HOST"]
  end
  teardown do
    disable_custom_domains!
    @saved_server_host.nil? ? ENV.delete("SERVER_HOST") : ENV["SERVER_HOST"] = @saved_server_host
  end

  def row(**attrs)
    CustomHostname.create!({ project: projects(:one), domain: domains(:one),
                             hostname: "links.selfhosted.com", status: "pending",
                             source: "enterprise", purpose: "primary" }.merge(attrs))
  end

  test "a cloudflare row carries no setup_records" do
    enable_custom_domains!
    payload = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: "cf_1", source: "saas"))

    assert_not payload.key?("setup_records")
    assert_equal "proxy.sqd.link", payload["cname_target"]
  end

  test "a manual row carries setup_records and the ingress host as its cname target" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    payload = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))

    assert_equal "links.app.com", payload["cname_target"]
    assert_equal 2, payload["setup_records"].size
  end

  test "an existing manual row keeps the ingress target after Cloudflare credentials appear" do
    ENV["SERVER_HOST"] = "links.app.com"
    ch = row(cf_custom_hostname_id: nil)
    enable_custom_domains!

    assert_equal "links.app.com", CustomHostnameSerializer.serialize(ch)["cname_target"]
  end

  # No credentials → no honest target; never fall back to the proxy.sqd.link default.
  test "an existing cloudflare row reports no target once credentials disappear" do
    ENV["SERVER_HOST"] = "links.app.com"
    enable_custom_domains!
    ch = row(cf_custom_hostname_id: "cf_1", source: "saas")
    enable_manual_custom_domains!

    assert_nil CustomHostnameSerializer.serialize(ch)["cname_target"]
  end

  # CNAME-before-cert makes the LB answer with its default cert while setup looks done.
  test "the certificate step precedes the DNS record" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    records = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))["setup_records"]

    assert_equal "certificate", records.first["kind"]
    assert_equal "dns", records.last["kind"]
  end

  test "the certificate step carries no record to copy" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    cert = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))["setup_records"].first

    assert_nil cert["name"]
    assert_nil cert["value"]
    assert cert["note"].present?
  end

  test "the dns record points at the deployment ingress" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    dns = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))["setup_records"].last

    assert_equal "CNAME", dns["type"]
    assert_equal "links.selfhosted.com", dns["name"]
    assert_equal "links.app.com", dns["value"]
  end

  test "SELF_HOSTED_INGRESS_HOST overrides SERVER_HOST" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    ENV["SELF_HOSTED_INGRESS_HOST"] = "alb.internal.example"
    dns = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))["setup_records"].last

    assert_equal "alb.internal.example", dns["value"]
  ensure
    ENV.delete("SELF_HOSTED_INGRESS_HOST")
  end

  # proxy.sqd.link is both the production default and the test fixture value.
  test "a manual row never advertises the Grovs SaaS proxy" do
    enable_manual_custom_domains!
    ENV["SERVER_HOST"] = "links.app.com"
    payload = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: nil))

    assert_not_equal "proxy.sqd.link", payload["cname_target"]
    payload["setup_records"].each { |r| assert_not_equal "proxy.sqd.link", r["value"] }
  end

  test "a cloudflare row keeps its configured target under the manual provider" do
    enable_manual_custom_domains!
    ENV["CLOUDFLARE_SAAS_CNAME_TARGET"] = "proxy.sqd.link"
    payload = CustomHostnameSerializer.serialize(row(cf_custom_hostname_id: "cf_1", source: "saas"))

    assert_equal "proxy.sqd.link", payload["cname_target"]
  end

  test "emits declared attributes plus computed cname_target" do
    enable_custom_domains!
    h = CustomHostnameSerializer.serialize(custom_hostnames(:acme_active))
    expected = %w[hostname status ssl_status verification_errors source purpose
                  ssl_method ssl_validation_txt_records
                  ownership_verification_txt_name ownership_verification_txt_value
                  last_checked_at cname_target]
    expected.each { |k| assert h.key?(k), "missing key #{k}" }
  end

  test "ssl_validation_txt_records is emitted as an array of {name, value} entries" do
    enable_custom_domains!
    ch = custom_hostnames(:acme_active)
    ch.update!(ssl_validation_txt_records: [
      { "name" => "_acme-challenge.x", "value" => "CA1" },
      { "name" => "_acme-challenge.x", "value" => "CA2" }
    ])
    h = CustomHostnameSerializer.serialize(ch.reload)
    assert_equal 2, h["ssl_validation_txt_records"].size
    assert_equal "CA1", h["ssl_validation_txt_records"][0]["value"]
    assert_equal "CA2", h["ssl_validation_txt_records"][1]["value"]
  end

  test "ssl_validation_txt_records emits [] (not null) on a fresh row" do
    enable_custom_domains!
    ch = row(hostname: "links.empty-array.example", status: "provisioning", source: "saas")
    h = CustomHostnameSerializer.serialize(ch)
    assert_equal [], h["ssl_validation_txt_records"],
                 "FE checks array.length — must always be an array, never null"
  end

  # Surfacing only one of the two TXT challenges is the bug that wedged tabkeep.uk on SSL.
  test "ownership_verification TXT fields surface the second TXT challenge to the dashboard" do
    enable_custom_domains!
    ch = custom_hostnames(:acme_active)
    ch.update!(ownership_verification_txt_name: "_cf-custom-hostname.links.acme.com",
               ownership_verification_txt_value: "a890192a-e150-4ee0-8f3a-4e14035ceb8b")
    h = CustomHostnameSerializer.serialize(ch.reload)
    assert_equal "_cf-custom-hostname.links.acme.com", h["ownership_verification_txt_name"]
    assert_equal "a890192a-e150-4ee0-8f3a-4e14035ceb8b", h["ownership_verification_txt_value"]
  end

  test "TXT-related fields are nil/[] when CF has not yet emitted a challenge" do
    enable_custom_domains!
    ch = row(hostname: "links.fresh.example", status: "provisioning", source: "saas",
             cf_custom_hostname_id: nil)
    h = CustomHostnameSerializer.serialize(ch)
    %w[ssl_method ownership_verification_txt_name ownership_verification_txt_value].each do |k|
      assert h.key?(k), "missing key #{k}"
      assert_nil h[k], "expected #{k} to be nil on a fresh row"
    end
    assert h.key?("ssl_validation_txt_records")
    assert_equal [], h["ssl_validation_txt_records"], "fresh row → empty array"
  end
end
