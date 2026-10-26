require "test_helper"

class SdkLinkCreationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
  end

  test "creates a link with no visitor and the given flags" do
    link = SdkLinkCreationService.create(
      project: @project, platform: "smart_banner", sdk_generated: false,
      data: { "page_path" => "/p/1" }, tags: ["smart_banner:1"],
      show_preview_ios: false, show_preview_android: false
    )

    assert link.persisted?
    assert_nil link.visitor_id
    assert_equal false, link.sdk_generated
    assert_equal "smart_banner", link.generated_from_platform
    assert_equal({ "page_path" => "/p/1" }, link.data)
    assert_equal ["smart_banner:1"], link.tags
    assert_equal false, link.show_preview_ios
    assert_equal false, link.show_preview_android
    assert_nil link.title
    assert_nil link.image_url
    assert_equal @project.domain_for_project, link.domain
    assert_equal @project.redirect_config, link.redirect_config
  end

  test "nil tags keep the column default" do
    link = SdkLinkCreationService.create(project: @project, platform: "ios")

    assert_equal [], link.tags
    assert link.sdk_generated
  end

  test "retries with a fresh path when another writer takes it first" do
    paths = [links(:basic_link).path, "s9b2c1"]

    LinksService.stub(:generate_valid_path, ->(_domain) { paths.shift }) do
      assert_equal "s9b2c1", SdkLinkCreationService.create(project: @project, platform: "ios").path
    end
  end
end
