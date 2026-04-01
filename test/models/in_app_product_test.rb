require "test_helper"

class InAppProductTest < ActiveSupport::TestCase
  fixtures :in_app_products, :in_app_product_daily_statistics, :projects, :instances

  test "belongs to project" do
    product = in_app_products(:premium_ios)
    assert_equal projects(:one), product.project
  end

  test "has_many in_app_product_daily_statistics with dependent destroy" do
    product = in_app_products(:premium_ios)
    assert product.in_app_product_daily_statistics.count > 0,
      "Fixture should have associated daily statistics"

    stat_ids = product.in_app_product_daily_statistics.pluck(:id)

    assert_difference "InAppProductDailyStatistic.count", -stat_ids.size do
      product.destroy
    end

    stat_ids.each do |stat_id|
      assert_nil InAppProductDailyStatistic.find_by(id: stat_id),
        "Daily statistic #{stat_id} should have been destroyed with the product"
    end
  end
end
