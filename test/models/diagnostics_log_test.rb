require "test_helper"

class DiagnosticsLogTest < ActiveSupport::TestCase
  # === validations: test_key ===

  test "valid with test_key and operation" do
    log = DiagnosticsLog.new(test_key: "project-abc", operation: "cache_read")
    assert log.valid?
  end

  test "invalid without test_key" do
    log = DiagnosticsLog.new(test_key: nil, operation: "cache_read")
    assert_not log.valid?
    assert_includes log.errors[:test_key], "can't be blank"
  end

  test "invalid with blank test_key" do
    log = DiagnosticsLog.new(test_key: "", operation: "cache_read")
    assert_not log.valid?
    assert_includes log.errors[:test_key], "can't be blank"
  end

  # === validations: operation ===

  test "invalid without operation" do
    log = DiagnosticsLog.new(test_key: "project-abc", operation: nil)
    assert_not log.valid?
    assert_includes log.errors[:operation], "can't be blank"
  end

  test "invalid with blank operation" do
    log = DiagnosticsLog.new(test_key: "project-abc", operation: "")
    assert_not log.valid?
    assert_includes log.errors[:operation], "can't be blank"
  end

  # === creation ===

  test "can be created with optional fields" do
    log = DiagnosticsLog.create!(
      test_key: "project-xyz",
      operation: "redis_write",
      payload: '{"key": "value"}',
      hostname: "worker-1",
      duration_ms: 12.5
    )

    assert_not_nil log.id
    assert_equal "project-xyz", log.test_key
    assert_equal "redis_write", log.operation
    assert_equal '{"key": "value"}', log.payload
    assert_equal "worker-1", log.hostname
    assert_in_delta 12.5, log.duration_ms, 0.01
  end
end
