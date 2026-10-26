require "test_helper"

class Experiments::GoalTest < ActiveSupport::TestCase
  def problem(goal) = Experiments::Goal.problem(goal)

  test "a purchase goal takes any product, or 1 to 20 products, and may wait 30 days" do
    assert_nil problem({ "purchase" => true, "window_hours" => 72 })
    assert_nil problem({ "purchase" => true, "products" => %w[premium coins], "window_hours" => 720 })
    assert_match(/products must be/, problem({ "purchase" => true, "products" => [], "window_hours" => 72 }))
    assert_match(/products must be/, problem({ "purchase" => true, "products" => ["x"] * 21, "window_hours" => 72 }))
    assert_match(/products must be/, problem({ "purchase" => true, "products" => [" "], "window_hours" => 72 }))
    assert_match(/products must be/, problem({ "purchase" => true, "products" => "premium", "window_hours" => 72 }))
    assert_match(/24, 72, 168 or 720/, problem({ "purchase" => true, "window_hours" => 48 }))
  end

  test "purchase must be true and alone, and products and 30 days belong to purchase goals only" do
    assert_match(/needs one event/, problem({ "purchase" => false, "window_hours" => 72 }))
    assert_match(/needs one event/, problem({ "purchase" => true, "event" => "checkout", "window_hours" => 72 }))
    assert_equal "products is only for a purchase goal", problem({ "event" => "checkout", "products" => ["premium"], "window_hours" => 72 })
    assert_equal "window_hours must be 24, 72 or 168", problem({ "event" => "checkout", "window_hours" => 720 })
  end

  test "event, screen and system goals are unchanged" do
    assert_nil problem({ "event" => "checkout", "window_hours" => 24 })
    assert_nil problem({ "screen" => "Checkout", "window_hours" => 168 })
    assert_nil problem({ "system" => "reactivation", "window_hours" => 72 })
    assert_equal "", Experiments::Goal.name({ "purchase" => true, "window_hours" => 72 })
    assert Experiments::Goal.purchase?({ "purchase" => true })
    assert_not Experiments::Goal.purchase?({ "event" => "purchase" })
  end
end
