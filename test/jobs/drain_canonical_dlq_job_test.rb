# frozen_string_literal: true

require "test_helper"

class DrainCanonicalDlqJobTest < ActiveJob::TestCase
  test "calls drain_canonical_dlq with the configured limit" do
    called_with = nil
    drain = lambda do |limit:|
      called_with = limit
      0
    end
    ClickhouseWriteService.stub(:drain_canonical_dlq, drain) do
      DrainCanonicalDlqJob.new.perform
    end
    assert_equal 100, called_with
  end

  test "swallows errors and never raises" do
    ClickhouseWriteService.stub(:drain_canonical_dlq, ->(**_kw) { raise StandardError, "drain boom" }) do
      assert_nothing_raised do
        DrainCanonicalDlqJob.new.perform
      end
    end
  end

  test "emits the DLQ depth metric each run" do
    recorded = nil
    Grovs::Metrics.stub(:histogram, ->(name, value, **_) { recorded = [name, value] }) do
      ClickhouseWriteService.stub(:drain_canonical_dlq, ->(**_) { 0 }) do
        ClickhouseWriteService.stub(:drain_purchase_dlq, ->(**_) { 0 }) do
          ClickhouseWriteService.stub(:dlq_depth, 42) do
            DrainCanonicalDlqJob.new.perform
          end
        end
      end
    end
    assert_equal ["clickhouse.dlq.depth", 42], recorded
  end

  test "logs an error when the backlog nears the cap" do
    over = (ClickhouseWriteService::CANONICAL_DLQ_MAX * DrainCanonicalDlqJob::ALERT_FRACTION).to_i + 1
    logged = false
    Rails.logger.stub(:error, ->(payload) { logged = true if payload.is_a?(Hash) && payload[:message] == "clickhouse_dlq_backlog" }) do
      ClickhouseWriteService.stub(:drain_canonical_dlq, ->(**_) { 0 }) do
        ClickhouseWriteService.stub(:drain_purchase_dlq, ->(**_) { 0 }) do
          ClickhouseWriteService.stub(:dlq_depth, over) do
            DrainCanonicalDlqJob.new.perform
          end
        end
      end
    end
    assert logged, "must log clickhouse_dlq_backlog when depth >= ALERT_FRACTION * cap"
  end

  test "does not log a backlog error when depth is low" do
    logged = false
    Rails.logger.stub(:error, ->(payload) { logged = true if payload.is_a?(Hash) && payload[:message] == "clickhouse_dlq_backlog" }) do
      ClickhouseWriteService.stub(:drain_canonical_dlq, ->(**_) { 0 }) do
        ClickhouseWriteService.stub(:drain_purchase_dlq, ->(**_) { 0 }) do
          ClickhouseWriteService.stub(:dlq_depth, 3) do
            DrainCanonicalDlqJob.new.perform
          end
        end
      end
    end
    assert_not logged
  end
end
