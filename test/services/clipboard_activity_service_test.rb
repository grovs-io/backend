require "test_helper"

class ClipboardActivityServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances

  setup do
    @project = projects(:one)
  end

  teardown do
    ClipboardActivityService.clear(@project)
  end

  test "active? is false without a stamp" do
    assert_equal false, ClipboardActivityService.active?(@project)
  end

  test "active? is true after a stamp and false for other projects" do
    ClipboardActivityService.stamp(@project)

    assert_equal true, ClipboardActivityService.active?(@project)
    assert_equal false, ClipboardActivityService.active?(projects(:two))
  end

  test "stamp expires with the clipboard validity window" do
    ClipboardActivityService.stamp(@project)

    ttl = REDIS.with { |conn| conn.ttl("clipboard:last_click:#{@project.id}") }
    assert ttl.positive?, "stamp must carry a TTL"
    assert ttl <= Grovs::Links::CLIPBOARD_VALIDITY.to_i
  end
end
