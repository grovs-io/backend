require "test_helper"

class SegmentsWindowTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 17, 12, 0, 0)
  CUTOFF = Date.new(2026, 1, 1)

  def normalize(raw, cap: 90)
    errors = []
    [Segments::Window.normalize(raw, cap_days: cap, cutoff_date: CUTOFF, path: "w", errors: errors), errors]
  end

  test "rolling window within the cap is accepted" do
    out, errors = normalize({ "last_days" => "30" })
    assert_equal({ "last_days" => 30 }, out)
    assert_empty errors
  end

  test "rolling window beyond the cap is rejected" do
    out, errors = normalize({ "last_days" => 91 })
    assert_nil out
    assert_equal "last_days must be between 1 and 90", errors.first[:message]
  end

  test "last_days rejects fractional or non-numeric strings" do
    _, e1 = normalize({ "last_days" => 30.5 })
    _, e2 = normalize({ "last_days" => "30d" })
    assert_match(/last_days/, e1.first[:message])
    assert_match(/last_days/, e2.first[:message])
    out, e3 = normalize({ "last_days" => "30" })
    assert_equal({ "last_days" => 30 }, out)
    assert_empty e3
  end

  test "fixed window is accepted when its span fits the cap and it starts after the cutoff" do
    out, = normalize({ "from" => "2026-06-01", "to" => "2026-06-30" })
    assert_equal({ "from" => "2026-06-01", "to" => "2026-06-30" }, out)
  end

  test "fixed window is rejected when it starts before the retention cutoff" do
    _, errors = normalize({ "from" => "2025-12-01", "to" => "2025-12-31" })
    assert_match(/retention/, errors.first[:message])
  end

  test "fixed window retention check is skipped when cutoff_date is nil" do
    errors = []
    out = Segments::Window.normalize({ "from" => "2020-01-01", "to" => "2020-01-31" },
                                      cap_days: 90, cutoff_date: nil, path: "w", errors: errors)
    assert_equal({ "from" => "2020-01-01", "to" => "2020-01-31" }, out)
    assert_empty errors
  end

  test "fixed window is rejected when from is after to or the span exceeds the cap" do
    _, e1 = normalize({ "from" => "2026-06-30", "to" => "2026-06-01" })
    _, e2 = normalize({ "from" => "2026-02-01", "to" => "2026-06-30" })
    assert_equal 1, e1.size
    assert_equal 1, e2.size
  end

  test "fixed window starting in the future is rejected, one only ending in the future is kept" do
    today = Time.now.utc.to_date
    _, errors = normalize({ "from" => (today + 1).iso8601, "to" => (today + 5).iso8601 })
    assert_equal ["window cannot start in the future"], errors.pluck(:message)
    out, errors = normalize({ "from" => today.iso8601, "to" => (today + 5).iso8601 })
    assert_equal today.iso8601, out["from"]
    assert_empty errors
  end

  test "rolling bounds start at day-alignment and end at now" do
    b = Segments::Window.bounds({ "last_days" => 7 }, cutoff_date: CUTOFF, now: NOW)
    assert_equal (NOW - 7.days).utc.beginning_of_day, b.from
    assert_equal NOW, b.to
    assert_not b.incomplete
  end

  test "fixed bounds never run past now, so future-dated events cannot match" do
    b = Segments::Window.bounds({ "from" => "2026-09-10", "to" => "2026-09-30" }, cutoff_date: CUTOFF, now: NOW)
    assert_equal NOW, b.to
  end

  test "a window that has aged past the cutoff is clamped and flagged incomplete" do
    b = Segments::Window.bounds({ "from" => "2026-06-01", "to" => "2026-06-30" }, cutoff_date: Date.new(2026, 6, 15), now: NOW)
    assert_equal Time.utc(2026, 6, 15), b.from
    assert b.incomplete
  end

  test "sql renders UTC DateTime64 bounds" do
    b = Segments::Window.bounds({ "last_days" => 1 }, cutoff_date: CUTOFF, now: NOW)
    assert_equal "created_at >= toDateTime64('2026-09-16 00:00:00.000', 3, 'UTC') AND " \
                 "created_at <= toDateTime64('2026-09-17 12:00:00.000', 3, 'UTC')",
                 Segments::Window.sql("created_at", b)
  end
end
