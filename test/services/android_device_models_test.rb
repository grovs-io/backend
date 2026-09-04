require "test_helper"
require "sidekiq/testing"

class AndroidDeviceModelsTest < ActiveSupport::TestCase
  setup do
    clear_state
    Sidekiq::Testing.fake!
    RefreshAndroidDeviceModelsJob.jobs.clear
  end

  teardown do
    clear_state
    RefreshAndroidDeviceModelsJob.jobs.clear
  end

  def clear_state
    REDIS.del(AndroidDeviceModels::KEY, AndroidDeviceModels::REFRESH_LOCK)
  end

  def seed(mapping)
    REDIS.with { |conn| conn.hset(AndroidDeviceModels::KEY, mapping) }
  end

  # Builds a plausible CSV body: UTF-16LE with BOM, expected headers, enough rows
  # to pass the size validation.
  def csv_body(rows: AndroidDeviceModels::MIN_CSV_ROWS + 10, headers: AndroidDeviceModels::EXPECTED_HEADERS)
    lines = [headers.map { |h| %("#{h}") }.join(",")]
    lines << %("Samsung","Galaxy S24 Ultra","e3q","SM-S928B")
    lines << %("Google","Pixel 8","shiba","Pixel 8")
    lines << %("","","AD681H","Smartfren Andromax AD681H")
    (rows - 3).times { |i| lines << %("Brand","Device #{i}","dev#{i}","MODEL-#{i}") }
    ("﻿" + lines.join("\r\n") + "\r\n").encode(Encoding::UTF_16LE).b
  end

  def refresh_with(body)
    AndroidDeviceModels.stub(:fetch_csv, body) { AndroidDeviceModels.refresh! }
  end

  # --- humanize ---

  test "maps a known model and passes unknown, blank, and nil through" do
    seed("SM-S928B" => "Samsung Galaxy S24 Ultra")

    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
    assert_equal "Foo123", AndroidDeviceModels.humanize("Foo123")
    assert_equal "", AndroidDeviceModels.humanize("")
    assert_nil AndroidDeviceModels.humanize(nil)
  end

  test "a miss with no table enqueues one refresh, misses with a table do not" do
    AndroidDeviceModels.humanize("SM-S928B")
    AndroidDeviceModels.humanize("SM-S928B")
    assert_equal 1, RefreshAndroidDeviceModelsJob.jobs.size, "NX lock must dedupe the cold-start trigger"

    RefreshAndroidDeviceModelsJob.jobs.clear
    REDIS.del(AndroidDeviceModels::REFRESH_LOCK)
    seed("Pixel 8" => "Google Pixel 8")

    AndroidDeviceModels.humanize("unmapped-model")
    assert_equal 0, RefreshAndroidDeviceModelsJob.jobs.size, "a populated table must not retrigger"
  end

  # --- refresh! ---

  test "refresh builds the table from a UTF-16LE download" do
    assert refresh_with(csv_body)

    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
    assert_equal "Google Pixel 8", AndroidDeviceModels.humanize("Pixel 8")
    assert_equal "Smartfren Andromax AD681H", AndroidDeviceModels.humanize("Smartfren Andromax AD681H"),
                 "rows without a marketing name must be skipped, not stored"
    assert REDIS.ttl(AndroidDeviceModels::KEY).negative?, "the live table must have no TTL"
  end

  test "a failed download keeps the previous table" do
    seed("SM-S928B" => "Samsung Galaxy S24 Ultra")

    assert_not refresh_with(nil)
    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
  end

  test "a truncated download keeps the previous table" do
    seed("SM-S928B" => "Samsung Galaxy S24 Ultra")

    assert_not refresh_with(csv_body(rows: 100))
    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
  end

  test "a download with unexpected headers keeps the previous table" do
    seed("SM-S928B" => "Samsung Galaxy S24 Ultra")

    assert_not refresh_with(csv_body(headers: ["Brand", "Name", "Device", "Model"]))
    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
  end

  test "garbage bytes keep the previous table" do
    seed("SM-S928B" => "Samsung Galaxy S24 Ultra")

    assert_not refresh_with("\xFF\xFE\x00garbage".b)
    assert_equal "Samsung Galaxy S24 Ultra", AndroidDeviceModels.humanize("SM-S928B")
  end
end
