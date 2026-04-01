require "test_helper"

class IapWebhookMessageTest < ActiveSupport::TestCase
  fixtures :projects, :instances

  # === validations: payload ===

  test "invalid without payload" do
    msg = IapWebhookMessage.new(payload: nil, source: Grovs::Webhooks::APPLE)
    assert_not msg.valid?
    assert_includes msg.errors[:payload], "can't be blank"
  end

  test "invalid with blank payload" do
    msg = IapWebhookMessage.new(payload: "", source: Grovs::Webhooks::APPLE)
    assert_not msg.valid?
    assert_includes msg.errors[:payload], "can't be blank"
  end

  # === validations: source presence ===

  test "invalid without source" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: nil)
    assert_not msg.valid?
    assert msg.errors[:source].any?
  end

  test "invalid with blank source" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: "")
    assert_not msg.valid?
    assert msg.errors[:source].any?
  end

  # === validations: source inclusion ===

  test "invalid with source not in SOURCES" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: "stripe")
    assert_not msg.valid?
    assert msg.errors[:source].any?
  end

  test "valid with apple source" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: Grovs::Webhooks::APPLE)
    assert msg.valid?
  end

  test "valid with google source" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: Grovs::Webhooks::GOOGLE)
    assert msg.valid?
  end

  # === optional associations ===

  test "valid without project and instance" do
    msg = IapWebhookMessage.new(payload: '{"test": true}', source: Grovs::Webhooks::APPLE)
    assert msg.valid?
  end

  test "valid with project and instance" do
    msg = IapWebhookMessage.new(
      payload: '{"test": true}',
      source: Grovs::Webhooks::GOOGLE,
      project: projects(:one),
      instance: instances(:one)
    )
    assert msg.valid?
  end
end
