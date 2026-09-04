# frozen_string_literal: true

require "test_helper"

class SyncVisitorProfileJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @original_write = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown { Rails.application.config.clickhouse_write_enabled = @original_write }

  test "writes the visitor's current identity into user_profiles" do
    @visitor.update!(sdk_identifier: "user-renamed")

    SyncVisitorProfileJob.new.perform(@visitor.id)

    row = profiles.find { |r| r["visitor_id"].to_i == @visitor.id }
    assert_equal "user-renamed", row["sdk_identifier"]
    assert_equal @visitor.uuid, row["uuid"]
    assert_equal "ios", row["platform"]
  end

  test "a cleared identifier is written as empty, not skipped" do
    @visitor.update!(sdk_identifier: nil)

    SyncVisitorProfileJob.new.perform(@visitor.id)

    assert_equal "", profiles.first["sdk_identifier"]
  end

  test "the row supersedes an older profile so sorting sees the new identity" do
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: @visitor.id, sdk_identifier: "stale", uuid: "",
      first_seen: 2.days.ago.utc.strftime("%Y-%m-%d %H:%M:%S.%3N"),
      last_seen: 2.days.ago.utc.strftime("%Y-%m-%d %H:%M:%S.%3N"), platform: "ios"
    }])
    @visitor.update!(sdk_identifier: "fresh")

    SyncVisitorProfileJob.new.perform(@visitor.id)

    latest = Clickhouse.with do |c|
      c.select_all("SELECT argMax(sdk_identifier, last_seen) AS sdk_identifier FROM user_profiles " \
                   "WHERE project_id = #{@project.id} AND visitor_id = #{@visitor.id}")
    end
    assert_equal "fresh", latest.first["sdk_identifier"]
  end

  test "malformed sdk_attributes degrade to an empty object instead of raising" do
    @visitor.update_column(:sdk_attributes, "not-json")

    assert_nothing_raised { SyncVisitorProfileJob.new.perform(@visitor.id) }
    assert_equal 1, profiles.length
  end

  test "a visitor deleted before the job runs is a no-op" do
    assert_nothing_raised { SyncVisitorProfileJob.new.perform(-1) }
    assert_empty profiles
  end

  # The write swallows CH errors and returns false; the job must surface it so Sidekiq retries.
  test "raises when the ClickHouse write fails, so the job is retried" do
    ClickhouseWriteService.stub(:upsert_user_profile, false) do
      assert_raises(SyncVisitorProfileJob::WriteFailedError) do
        SyncVisitorProfileJob.new.perform(@visitor.id)
      end
    end
  end

  test "does nothing when ClickHouse is disabled" do
    Rails.application.config.clickhouse_write_enabled = false

    called = false
    ClickhouseWriteService.stub(:upsert_user_profile, ->(_row) { called = true }) do
      SyncVisitorProfileJob.new.perform(@visitor.id)
    end
    assert_not called
  end

  private

  def profiles
    Clickhouse.with do |c|
      c.select_all("SELECT * FROM user_profiles WHERE project_id = #{@project.id} ORDER BY visitor_id")
    end
  end
end
