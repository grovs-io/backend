require "test_helper"

class RefreshPurchaseClickhouseRowJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  test "re-delivers the row one millisecond past created_at, not at Time.current" do
    event = purchase_events(:unprocessed_buy)
    captured = nil

    ProcessPurchaseEventJob.stub(:dual_write_clickhouse, ->(_e, version_ts:) { captured = version_ts }) do
      RefreshPurchaseClickhouseRowJob.new.perform(event.id)
    end

    assert_equal event.created_at + 0.001.seconds, captured
    assert_equal event.created_at.strftime("%Y%m"), captured.strftime("%Y%m"), "must stay in the same CH partition"
  end

  test "does nothing when the purchase is gone" do
    called = false

    ProcessPurchaseEventJob.stub(:dual_write_clickhouse, ->(*_a, **_kw) { called = true }) do
      RefreshPurchaseClickhouseRowJob.new.perform(-1)
    end

    assert_not called
  end
end
