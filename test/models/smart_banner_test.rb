require "test_helper"

class SmartBannerTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @banner = SmartBanner.new(project: projects(:one), name: "Main", title: "Get the app")
  end

  test "defaults are valid" do
    assert @banner.valid?, @banner.errors.full_messages.inspect
    assert_equal %w[ios android], @banner.platforms
    assert_equal "top", @banner.position
    assert_equal 7, @banner.dismiss_days
    assert_equal 30, @banner.open_hide_days
    assert_equal "draft", @banner.status
  end

  test "status must be in the catalogue, and only draft or live on create" do
    @banner.status = "bogus"
    assert_not @banner.valid?
    assert_includes @banner.errors.attribute_names, :status

    @banner.status = "paused"
    assert_not @banner.valid?
    @banner.status = "archived"
    assert_not @banner.valid?

    @banner.status = "live"
    assert @banner.valid?
  end

  test "an existing banner can transition to any catalogue status" do
    @banner.status = "live"
    @banner.save!

    @banner.status = "paused"
    assert @banner.valid?
    @banner.status = "archived"
    assert @banner.valid?
  end

  test "requires name, title and button text" do
    @banner.assign_attributes(name: "", title: "", button_text: "")
    assert_not @banner.valid?
    assert_includes @banner.errors.attribute_names, :name
    assert_includes @banner.errors.attribute_names, :title
    assert_includes @banner.errors.attribute_names, :button_text
  end

  test "platforms must be a non-empty subset of ios and android" do
    @banner.platforms = []
    assert_not @banner.valid?
    @banner.platforms = %w[ios web]
    assert_not @banner.valid?
    @banner.platforms = %w[android]
    assert @banner.valid?
  end

  test "url patterns must start with a slash, stay short and number at most 20" do
    @banner.url_include = ["products/*"]
    assert_not @banner.valid?
    @banner.url_include = ["/#{'a' * 256}"]
    assert_not @banner.valid?
    @banner.url_include = Array.new(21) { |i| "/p/#{i}" }
    assert_not @banner.valid?
    @banner.url_include = ["/products/*"]
    @banner.url_exclude = ["/products/hidden"]
    assert @banner.valid?
  end

  test "position, colors and dismiss days are checked" do
    @banner.position = "middle"
    assert_not @banner.valid?
    @banner.position = "bottom"
    @banner.background_color = "red"
    assert_not @banner.valid?
    @banner.background_color = "#00ff00"
    @banner.dismiss_days = 366
    assert_not @banner.valid?
    @banner.dismiss_days = 0
    assert @banner.valid?
    @banner.open_hide_days = 366
    assert_not @banner.valid?
    @banner.open_hide_days = 0
    assert @banner.valid?
    @banner.open_hide_days = 365
    assert @banner.valid?
  end

  test "icon must be a small png, jpeg or webp" do
    @banner.icon = { io: StringIO.new("plain"), filename: "icon.txt", content_type: "text/plain" }
    assert_not @banner.valid?
    assert_includes @banner.errors[:icon], "must be PNG, JPEG or WebP"

    @banner.icon = { io: StringIO.new("x" * (1.megabyte + 1)), filename: "big.png", content_type: "image/png" }
    assert_not @banner.valid?
    assert_includes @banner.errors[:icon], "must be at most 1 MB"
  end
end
