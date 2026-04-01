require "test_helper"

class GoogleIapService::RentalSupportTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # determine_purchase_type
  # ---------------------------------------------------------------------------

  test "determine_purchase_type returns rental when rental detected" do
    offer = OpenStruct.new(rent_offer_details: OpenStruct.new)
    item = OpenStruct.new(product_offer_details: offer)
    assert_equal Grovs::Purchases::TYPE_RENTAL,
                 GoogleIapService::RentalSupport.determine_purchase_type(item)
  end

  test "determine_purchase_type returns one_time when no rental indicators" do
    item = OpenStruct.new(product_id: "com.test.item")
    assert_equal Grovs::Purchases::TYPE_ONE_TIME,
                 GoogleIapService::RentalSupport.determine_purchase_type(item)
  end

  test "determine_purchase_type returns one_time for nil" do
    assert_equal Grovs::Purchases::TYPE_ONE_TIME,
                 GoogleIapService::RentalSupport.determine_purchase_type(nil)
  end

  # ---------------------------------------------------------------------------
  # rental? — Path 1: ProductLineItem.product_offer_details.rent_offer_details
  # ---------------------------------------------------------------------------

  test "rental? detects rental via product_offer_details.rent_offer_details" do
    offer = OpenStruct.new(rent_offer_details: OpenStruct.new)
    item = OpenStruct.new(product_offer_details: offer)

    assert GoogleIapService::RentalSupport.rental?(item)
  end

  test "rental? returns false when rent_offer_details is nil" do
    offer = OpenStruct.new(rent_offer_details: nil)
    item = OpenStruct.new(product_offer_details: offer)

    assert_not GoogleIapService::RentalSupport.rental?(item)
  end

  test "rental? returns false when product_offer_details is nil" do
    item = OpenStruct.new(product_offer_details: nil)
    assert_not GoogleIapService::RentalSupport.rental?(item)
  end

  # ---------------------------------------------------------------------------
  # rental? — Path 2: ProductPurchaseV2.product_line_item[].product_offer_details
  # ---------------------------------------------------------------------------

  test "rental? detects rental via product_line_item on v2 response" do
    offer = OpenStruct.new(rent_offer_details: OpenStruct.new)
    line_item = OpenStruct.new(product_offer_details: offer)
    purchase_v2 = OpenStruct.new(product_line_item: [line_item])

    assert GoogleIapService::RentalSupport.rental?(purchase_v2)
  end

  test "rental? returns false when no v2 line items are rentals" do
    offer = OpenStruct.new(rent_offer_details: nil)
    line_item = OpenStruct.new(product_offer_details: offer)
    purchase_v2 = OpenStruct.new(product_line_item: [line_item])

    assert_not GoogleIapService::RentalSupport.rental?(purchase_v2)
  end

  # ---------------------------------------------------------------------------
  # rental? — no indicators
  # ---------------------------------------------------------------------------

  test "rental? returns false for plain object without rental indicators" do
    item = OpenStruct.new(product_id: "com.test.gems")
    assert_not GoogleIapService::RentalSupport.rental?(item)
  end
end
