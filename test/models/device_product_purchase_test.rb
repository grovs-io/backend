require "test_helper"

class DeviceProductPurchaseTest < ActiveSupport::TestCase
  fixtures :devices, :projects

  # === creation ===

  test "can create a device product purchase with valid attributes" do
    purchase = DeviceProductPurchase.create!(
      device: devices(:ios_device),
      project: projects(:one),
      product_id: "com.example.premium"
    )

    assert purchase.persisted?
    assert_equal "com.example.premium", purchase.product_id
  end

  test "enforces unique constraint on device, project, and product_id combination" do
    DeviceProductPurchase.create!(
      device: devices(:ios_device),
      project: projects(:one),
      product_id: "com.example.premium"
    )

    duplicate = DeviceProductPurchase.new(
      device: devices(:ios_device),
      project: projects(:one),
      product_id: "com.example.premium"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test "allows same product_id for different devices" do
    purchase1 = DeviceProductPurchase.create!(
      device: devices(:ios_device),
      project: projects(:one),
      product_id: "com.example.premium"
    )

    purchase2 = DeviceProductPurchase.create!(
      device: devices(:android_device),
      project: projects(:one),
      product_id: "com.example.premium"
    )

    assert purchase1.persisted?
    assert purchase2.persisted?
  end
end
