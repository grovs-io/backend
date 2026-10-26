require "test_helper"

class Billing::PlansTest < ActiveSupport::TestCase
  test "flat? is true only for the three flat keys" do
    %w[growth_250k growth_500k scale_1m].each { |k| assert Billing::Plans.flat?(k), k }
    ["scale_up", "pro", "enterprise", nil, ""].each { |k| assert_not Billing::Plans.flat?(k), k.inspect }
  end

  test "valid? needs a flat key and a known interval" do
    assert Billing::Plans.valid?("growth_250k", "monthly")
    assert Billing::Plans.valid?("scale_1m", "yearly")
    assert_not Billing::Plans.valid?("scale_up", "monthly")
    assert_not Billing::Plans.valid?("growth_250k", "weekly")
    assert_not Billing::Plans.valid?(nil, nil)
  end

  test "valid? is false when the price ENV is missing, so the API answers 422 not 500" do
    original = ENV.delete("STRIPE_PRICE_SCALE_1M_YEARLY")
    assert_not Billing::Plans.valid?("scale_1m", "yearly")
  ensure
    ENV["STRIPE_PRICE_SCALE_1M_YEARLY"] = original
  end

  test "price resolves from ENV and rejects unknown input" do
    assert_equal "price_test_g500_y", Billing::Plans.price("growth_500k", "yearly")
    assert_raises(Billing::Plans::UnknownPlan) { Billing::Plans.price("scale_up", "monthly") }
  end

  test "for_price maps every configured price back to its key" do
    assert_equal "growth_250k", Billing::Plans.for_price("price_test_g250_m")
    assert_equal "scale_1m", Billing::Plans.for_price("price_test_s1m_y")
    assert_nil Billing::Plans.for_price(ENV["STRIPE_STANDARD_PRICE_ID"])
    assert_nil Billing::Plans.for_price(nil)
  end

  test "mau_cap per plan" do
    assert_equal 250_000, Billing::Plans.mau_cap("growth_250k")
    assert_equal 500_000, Billing::Plans.mau_cap("growth_500k")
    assert_equal 1_000_000, Billing::Plans.mau_cap("scale_1m")
    assert_nil Billing::Plans.mau_cap("scale_up")
  end
end
