require "test_helper"

class InAppProductDailyStatisticTest < ActiveSupport::TestCase
  fixtures :in_app_product_daily_statistics, :in_app_products, :projects, :instances

  test "belongs to in_app_product" do
    stat = in_app_product_daily_statistics(:premium_day1)
    assert_equal in_app_products(:premium_ios), stat.in_app_product
  end

  test "belongs to project" do
    stat = in_app_product_daily_statistics(:premium_day1)
    assert_equal projects(:one), stat.project
  end

  test "destroying parent in_app_product cascades to daily statistics" do
    product = in_app_products(:premium_ios)
    stat_id = in_app_product_daily_statistics(:premium_day1).id

    product.destroy

    assert_nil InAppProductDailyStatistic.find_by(id: stat_id),
      "Daily statistic should be destroyed when parent product is destroyed"
  end
end
