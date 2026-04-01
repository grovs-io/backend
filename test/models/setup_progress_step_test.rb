require "test_helper"

class SetupProgressStepTest < ActiveSupport::TestCase
  fixtures :instances

  # === validations: category ===

  test "valid with ios_setup category" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "register_app"
    )
    assert step.valid?
  end

  test "valid with android_setup category" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "android_setup",
      step_identifier: "register_app"
    )
    assert step.valid?
  end

  test "valid with web_setup category" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "web_setup",
      step_identifier: "register_domains"
    )
    assert step.valid?
  end

  test "invalid with unrecognized category" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "desktop_setup",
      step_identifier: "register_app"
    )
    assert_not step.valid?
    assert_includes step.errors[:category], "is not included in the list"
  end

  test "invalid with blank category" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "",
      step_identifier: "register_app"
    )
    assert_not step.valid?
  end

  # === validations: step_identifier ===

  test "valid with each recognized step_identifier" do
    SetupProgressStep::VALID_STEP_IDENTIFIERS.each do |identifier|
      step = SetupProgressStep.new(
        instance: instances(:one),
        category: "ios_setup",
        step_identifier: identifier
      )
      assert step.valid?, "Expected step_identifier '#{identifier}' to be valid"
    end
  end

  test "invalid with unrecognized step_identifier" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "unknown_step"
    )
    assert_not step.valid?
    assert_includes step.errors[:step_identifier], "is not included in the list"
  end

  test "invalid with blank step_identifier" do
    step = SetupProgressStep.new(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: ""
    )
    assert_not step.valid?
  end

  # === validations: uniqueness scoped to instance_id + category ===

  test "enforces uniqueness of step_identifier scoped to instance and category" do
    SetupProgressStep.create!(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "register_app"
    )

    duplicate = SetupProgressStep.new(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "register_app"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:step_identifier], "has already been taken"
  end

  test "allows same step_identifier for different categories on same instance" do
    step1 = SetupProgressStep.create!(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "register_app"
    )

    step2 = SetupProgressStep.new(
      instance: instances(:one),
      category: "android_setup",
      step_identifier: "register_app"
    )
    assert step2.valid?
  end

  test "allows same step_identifier and category on different instances" do
    step1 = SetupProgressStep.create!(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "add_sdk"
    )

    step2 = SetupProgressStep.new(
      instance: instances(:two),
      category: "ios_setup",
      step_identifier: "add_sdk"
    )
    assert step2.valid?
  end

  # === serialization ===

  test "serializer excludes id, instance_id, created_at, and updated_at" do
    step = SetupProgressStep.create!(
      instance: instances(:one),
      category: "ios_setup",
      step_identifier: "push_notifications"
    )

    json = SetupProgressStepSerializer.serialize(step)

    assert_not json.key?("id")
    assert_not json.key?("instance_id")
    assert_not json.key?("created_at")
    assert_not json.key?("updated_at")
  end

  test "serializer includes category and step_identifier" do
    step = SetupProgressStep.create!(
      instance: instances(:one),
      category: "android_setup",
      step_identifier: "intent_filters"
    )

    json = SetupProgressStepSerializer.serialize(step)

    assert_equal "android_setup", json["category"]
    assert_equal "intent_filters", json["step_identifier"]
  end
end
