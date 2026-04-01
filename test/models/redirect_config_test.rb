require "test_helper"

class RedirectConfigTest < ActiveSupport::TestCase
  fixtures :redirect_configs, :projects, :redirects, :applications, :instances, :domains, :links, :custom_redirects

  # === associations ===

  test "has_many redirects with dependent delete_all" do
    rc = redirect_configs(:one)
    assert rc.redirects.count > 0

    # Clean up records that reference links owned by this redirect_config,
    # since links use delete_all which bypasses callbacks/cascading.
    link_ids = rc.links.pluck(:id)
    VisitorLastVisit.where(link_id: link_ids).delete_all
    CustomRedirect.where(link_id: link_ids).delete_all

    assert_difference "Redirect.count", -rc.redirects.count do
      rc.destroy
    end
  end

  # === redirect_for_platform_and_variation ===

  test "redirect_for_platform_and_variation returns existing redirect" do
    rc = redirect_configs(:one)
    existing = redirects(:ios_phone_redirect)

    result = rc.redirect_for_platform_and_variation(Grovs::Platforms::IOS, Grovs::Platforms::PHONE)
    assert_equal existing.id, result.id
  end

  test "redirect_for_platform_and_variation creates new redirect if missing" do
    rc = redirect_configs(:one)

    assert_difference "Redirect.count", 1 do
      result = rc.redirect_for_platform_and_variation(Grovs::Platforms::IOS, Grovs::Platforms::TABLET)
      assert_equal Grovs::Platforms::IOS, result.platform
      assert_equal Grovs::Platforms::TABLET, result.variation
      assert_equal rc.id, result.redirect_config_id
    end
  end

  test "redirect_for_platform_and_variation sets correct application_id from instance" do
    rc = redirect_configs(:one)
    ios_application = rc.project.instance.application_for_platform(Grovs::Platforms::IOS)

    result = rc.redirect_for_platform_and_variation(Grovs::Platforms::IOS, Grovs::Platforms::TABLET)
    assert_equal ios_application.id, result.application_id,
      "New redirect should reference the instance's iOS application"
  end

  # === serialization ===

  test "serializer structures redirects by platform and variation" do
    rc = redirect_configs(:one)
    json = RedirectConfigSerializer.serialize(rc)

    assert json.key?("ios")
    assert json["ios"].key?("phone")
    assert json["ios"].key?("tablet")

    assert json.key?("android")
    assert json["android"].key?("phone")
    assert json["android"].key?("tablet")

    assert json.key?("desktop")
    assert json["desktop"].key?("all")
  end

  test "serializer ios phone redirect matches fixture redirect" do
    rc = redirect_configs(:one)
    json = RedirectConfigSerializer.serialize(rc)

    ios_phone = json["ios"]["phone"]
    assert_not_nil ios_phone
    assert_equal Grovs::Platforms::IOS, ios_phone["platform"]
    assert_equal Grovs::Platforms::PHONE, ios_phone["variation"]
  end

  test "serializer excludes internal fields" do
    rc = redirect_configs(:one)
    json = RedirectConfigSerializer.serialize(rc)

    assert_nil json["id"]
    assert_nil json["created_at"]
    assert_nil json["updated_at"]
  end
end
