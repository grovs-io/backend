require "test_helper"

class GoogleIapService::QuantitySupportTest < ActiveSupport::TestCase
  test "extract_quantity returns quantity from purchase data" do
    data = OpenStruct.new(quantity: 5)
    assert_equal 5, GoogleIapService::QuantitySupport.extract_quantity(data)
  end

  test "extract_quantity returns 1 when quantity is nil" do
    data = OpenStruct.new(quantity: nil)
    assert_equal 1, GoogleIapService::QuantitySupport.extract_quantity(data)
  end

  test "extract_quantity returns 1 when quantity is 0" do
    data = OpenStruct.new(quantity: 0)
    assert_equal 1, GoogleIapService::QuantitySupport.extract_quantity(data)
  end

  test "extract_quantity returns 1 when quantity is negative" do
    data = OpenStruct.new(quantity: -1)
    assert_equal 1, GoogleIapService::QuantitySupport.extract_quantity(data)
  end

  test "extract_quantity returns 1 when object does not respond to quantity" do
    data = Object.new
    assert_equal 1, GoogleIapService::QuantitySupport.extract_quantity(data)
  end

  test "extract_quantity converts string quantity to integer" do
    data = OpenStruct.new(quantity: "3")
    assert_equal 3, GoogleIapService::QuantitySupport.extract_quantity(data)
  end
end
