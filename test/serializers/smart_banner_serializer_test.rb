require "test_helper"

class SmartBannerSerializerTest < ActiveSupport::TestCase
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs

  test "sdk returns nil for a banner without a default link" do
    banner = create_test_banner(projects(:one))
    banner.update_column(:default_link_id, nil)

    assert_nil SmartBannerSerializer.sdk(banner)
  end

  test "build returns a nil default_link instead of raising" do
    banner = create_test_banner(projects(:one))
    banner.update_column(:default_link_id, nil)

    result = SmartBannerSerializer.new(banner).build
    assert_nil result["default_link"]
  end
end
