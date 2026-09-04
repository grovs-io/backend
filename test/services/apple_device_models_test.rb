require "test_helper"

class AppleDeviceModelsTest < ActiveSupport::TestCase
  test "maps known iPhone identifiers to marketing names" do
    assert_equal "iPhone 16", AppleDeviceModels.humanize("iPhone17,3")
    assert_equal "iPhone 17 Pro Max", AppleDeviceModels.humanize("iPhone18,2")
    assert_equal "iPhone SE (3rd generation)", AppleDeviceModels.humanize("iPhone14,6")
  end

  test "maps every identifier of a multi-identifier model to the same name" do
    assert_equal "iPhone 7", AppleDeviceModels.humanize("iPhone9,1")
    assert_equal "iPhone 7", AppleDeviceModels.humanize("iPhone9,3")
    assert_equal "iPad 2", AppleDeviceModels.humanize("iPad2,4")
  end

  test "maps known iPad and iPod identifiers" do
    assert_equal "iPad Pro 13-inch (M4)", AppleDeviceModels.humanize("iPad16,5")
    assert_equal "iPod touch (7th generation)", AppleDeviceModels.humanize("iPod9,1")
  end

  test "unknown identifiers pass through untouched" do
    assert_equal "iPhone99,9", AppleDeviceModels.humanize("iPhone99,9")
    assert_equal "iPad99,1", AppleDeviceModels.humanize("iPad99,1")
  end

  test "marketing names from older SDKs pass through untouched" do
    assert_equal "iPhone 15 Pro", AppleDeviceModels.humanize("iPhone 15 Pro")
    assert_equal "iPad Pro (11-inch) (3rd generation)",
                 AppleDeviceModels.humanize("iPad Pro (11-inch) (3rd generation)")
  end

  test "non-Apple and simulator values pass through untouched" do
    assert_equal "SM-S928B", AppleDeviceModels.humanize("SM-S928B")
    assert_equal "Pixel 8 Pro", AppleDeviceModels.humanize("Pixel 8 Pro")
    assert_equal "arm64", AppleDeviceModels.humanize("arm64")
    assert_equal "x86_64", AppleDeviceModels.humanize("x86_64")
  end

  test "nil and empty values pass through untouched" do
    assert_nil AppleDeviceModels.humanize(nil)
    assert_equal "", AppleDeviceModels.humanize("")
  end

  test "identifier lookalikes with wrong shape pass through untouched" do
    assert_equal "iPhone17,3 ", AppleDeviceModels.humanize("iPhone17,3 ")
    assert_equal "iphone17,3", AppleDeviceModels.humanize("iphone17,3")
    assert_equal "iPhone17", AppleDeviceModels.humanize("iPhone17")
  end

  test "every table key is a well-formed identifier" do
    AppleDeviceModels::NAMES.each_key do |key|
      assert_match AppleDeviceModels::IDENTIFIER_PATTERN, key,
                   "table key #{key.inspect} would never be matched by the gate"
    end
  end
end
