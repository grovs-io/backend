require "test_helper"

class StoreImageTest < ActiveSupport::TestCase
  fixtures :store_images

  # === identifier validation ===

  test "valid with identifier present" do
    image = store_images(:app_icon)
    assert image.valid?
  end

  test "invalid without identifier" do
    image = StoreImage.new(identifier: nil, platform: "ios")
    assert_not image.valid?
    assert image.errors[:identifier].any?
  end

  test "invalid with blank identifier" do
    image = StoreImage.new(identifier: "", platform: "ios")
    assert_not image.valid?
    assert image.errors[:identifier].any?
  end

  # === image_access_url ===

  test "image_access_url delegates to AssetService.permanent_url" do
    image = store_images(:app_icon)
    expected_url = "https://cdn.example.com/store-image.png"

    AssetService.stub(:permanent_url, expected_url) do
      assert_equal expected_url, image.image_access_url
    end
  end

  test "image_access_url returns nil when no image attached" do
    image = store_images(:app_icon)

    AssetService.stub(:permanent_url, nil) do
      assert_nil image.image_access_url
    end
  end
end
