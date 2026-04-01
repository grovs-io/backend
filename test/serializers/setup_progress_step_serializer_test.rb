require "test_helper"

class SetupProgressStepSerializerTest < ActiveSupport::TestCase
  fixtures :instances

  def setup
    @completed_time = Time.current
    @step = SetupProgressStep.create!(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "register_app",
      completed_at: @completed_time
    )
    @step_without_completed = SetupProgressStep.create!(
      instance: instances(:one),
      category: "android_setup",
      step_identifier: "add_sdk",
      completed_at: nil
    )
  end

  def teardown
    SetupProgressStep.where(instance: instances(:one)).delete_all
  end

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes completed step with correct attribute values" do
    result = SetupProgressStepSerializer.serialize(@step)

    assert_equal "ios_setup",                       result["category"]
    assert_equal "register_app",                    result["step_identifier"]
    assert_not_nil result["completed_at"], "Expected completed_at to be present for a completed step"
    assert_equal @completed_time.to_i, result["completed_at"].to_i
  end

  test "serializes incomplete step with correct attribute values" do
    result = SetupProgressStepSerializer.serialize(@step_without_completed)

    assert_equal "android_setup",                   result["category"]
    assert_equal "add_sdk",                         result["step_identifier"]
    assert_nil                                      result["completed_at"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes id instance_id created_at and updated_at" do
    result = SetupProgressStepSerializer.serialize(@step)

    %w[id instance_id created_at updated_at].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil SetupProgressStepSerializer.serialize(nil)
  end

  test "completed_at is nil when step is not completed" do
    result = SetupProgressStepSerializer.serialize(@step_without_completed)

    assert result.key?("completed_at"), "Expected key 'completed_at' to be present"
    assert_nil result["completed_at"]
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct categories" do
    result = SetupProgressStepSerializer.serialize([@step, @step_without_completed])

    assert_equal 2, result.size
    assert_equal "ios_setup",     result[0]["category"]
    assert_equal "android_setup", result[1]["category"]
    assert_equal "register_app",  result[0]["step_identifier"]
    assert_equal "add_sdk",       result[1]["step_identifier"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "only exposes exactly three keys" do
    result = SetupProgressStepSerializer.serialize(@step)

    assert_equal %w[category completed_at step_identifier], result.keys.sort
  end

  test "serializes empty collection as empty array" do
    result = SetupProgressStepSerializer.serialize([])
    assert_equal [], result
  end
end
