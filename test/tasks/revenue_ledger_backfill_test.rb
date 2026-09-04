# frozen_string_literal: true

require "test_helper"
require "rake"

class RevenueLedgerBackfillTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "revenue_ledger:backfill_snapshots" }
    @task = Rake::Task["revenue_ledger:backfill_snapshots"]
    @project = projects(:one)
  end

  teardown { @task.reenable }

  test "fills date, visitor_id and revenue_platform per the snapshot rules" do
    store_row  = legacy_row(device: devices(:ios_device), store_source: "google")
    device_row = legacy_row(device: devices(:android_device))
    nodev_row  = legacy_row(device: nil)
    unprocessed = legacy_row(device: devices(:ios_device), processed: false)

    weird_device = Device.create!(user_agent: "Legacy/1", ip: "10.9.9.9", remote_ip: "10.9.9.9",
                                  platform: "macos", vendor: "bf-weird-#{SecureRandom.hex(3)}")
    weird_row = legacy_row(device: weird_device)

    run_task_quietly

    assert_equal "android", store_row.reload.revenue_platform, "store_source wins"
    assert_equal visitors(:ios_visitor).id, store_row.visitor_id
    assert_equal store_row.created_at.to_i, store_row.date.to_i, "NULL date backfilled from created_at"

    assert_equal "android", device_row.reload.revenue_platform, "device platform used without store_source"
    assert_equal visitors(:android_visitor).id, device_row.visitor_id

    assert_equal "web", nodev_row.reload.revenue_platform, "no device and no store_source → web"
    assert_nil nodev_row.visitor_id, "unresolvable rows stay NULL"

    assert_equal "web", weird_row.reload.revenue_platform, "non-mobile device platform normalizes to web"

    unprocessed.reload
    assert_nil unprocessed.revenue_platform, "unprocessed rows get snapshots at processing time, not backfill"
    assert_nil unprocessed.visitor_id
    assert_not_nil unprocessed.date, "date backfills regardless of processed"
  end

  test "is idempotent and never overwrites an existing snapshot" do
    row = legacy_row(device: devices(:ios_device))
    row.update_columns(revenue_platform: "sentinel", visitor_id: 42)

    run_task_quietly

    row.reload
    assert_equal "sentinel", row.revenue_platform
    assert_equal 42, row.visitor_id
  end

  private

  # A pre-snapshot-era row: created normally, then columns nulled as legacy data would be.
  def legacy_row(device:, store_source: nil, processed: true)
    pe = PurchaseEvent.create!(
      project: @project, device: device, store_source: store_source,
      event_type: Grovs::Purchases::EVENT_BUY, usd_price_cents: 100,
      transaction_id: "bf_#{SecureRandom.hex(5)}", processed: processed
    )
    pe.update_columns(date: nil, revenue_platform: nil, visitor_id: nil)
    pe
  end

  def run_task_quietly
    silence_stream($stdout) { @task.invoke }
  ensure
    @task.reenable
  end

  def silence_stream(stream)
    old = stream.dup
    stream.reopen(File::NULL, "w")
    yield
  ensure
    stream.reopen(old)
  end
end
