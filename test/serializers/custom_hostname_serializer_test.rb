require "test_helper"

class CustomHostnameSerializerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :custom_hostnames

  test "emits declared attributes plus computed cname_target" do
    h = CustomHostnameSerializer.serialize(custom_hostnames(:acme_active))
    expected = %w[hostname status ssl_status verification_errors source purpose
                  ssl_method ssl_validation_txt_records
                  ownership_verification_txt_name ownership_verification_txt_value
                  last_checked_at cname_target]
    expected.each { |k| assert h.key?(k), "missing key #{k}" }
  end

  test "ssl_validation_txt_records is emitted as an array of {name, value} entries" do
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
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.empty-array.example", status: "provisioning",
                                source: "saas",
                                purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    h = CustomHostnameSerializer.serialize(ch)
    assert_equal [], h["ssl_validation_txt_records"],
                 "FE checks array.length — must always be an array, never null"
  end

  test "ownership_verification TXT fields surface the second TXT challenge to the dashboard" do
    # The hostname pre-validation TXT lives in a separate column pair. The dashboard
    # needs both the _acme-challenge record AND this one side-by-side; surfacing only
    # one is the bug that wedged tabkeep.uk on SSL provisioning.
    ch = custom_hostnames(:acme_active)
    ch.update!(ownership_verification_txt_name: "_cf-custom-hostname.links.acme.com",
               ownership_verification_txt_value: "a890192a-e150-4ee0-8f3a-4e14035ceb8b")
    h = CustomHostnameSerializer.serialize(ch.reload)
    assert_equal "_cf-custom-hostname.links.acme.com", h["ownership_verification_txt_name"]
    assert_equal "a890192a-e150-4ee0-8f3a-4e14035ceb8b", h["ownership_verification_txt_value"]
  end

  test "TXT-related fields are nil/[] when CF has not yet emitted a challenge" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one),
                                hostname: "links.fresh.example", status: "provisioning",
                                source: "saas",
                                purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    h = CustomHostnameSerializer.serialize(ch)
    %w[ssl_method ownership_verification_txt_name ownership_verification_txt_value].each do |k|
      assert h.key?(k), "missing key #{k}"
      assert_nil h[k], "expected #{k} to be nil on a fresh row"
    end
    assert h.key?("ssl_validation_txt_records")
    assert_equal [], h["ssl_validation_txt_records"], "fresh row → empty array"
  end
end
