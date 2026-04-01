require "test_helper"

class EventFlushServiceTest < ActiveSupport::TestCase
  test "flush with no events returns zero counts and runs generators" do
    metrics_dates = []
    dau_dates = []

    DailyProjectMetricsGenerator.stub(:call, lambda { |date|
      metrics_dates << date
    }) do
      ProjectDailyActiveUsersGenerator.stub(:call, lambda { |date|
        dau_dates << date
      }) do
        REDIS.stub(:rpop, nil) do
          result = EventFlushService.flush(aggregate_days: 1)

          assert_equal 0, result[:processed]
          assert_equal 0, result[:discarded]
          assert_equal 1, result[:dates_aggregated].size
          assert_equal Date.today.to_s, result[:dates_aggregated].first

          # Verify generators were called with correct dates
          assert_equal [Date.today], metrics_dates
          assert_equal [Date.today], dau_dates
        end
      end
    end
  end

  test "flush clamps aggregate_days to maximum of 7" do
    DailyProjectMetricsGenerator.stub(:call, ->(_date) { nil }) do
      ProjectDailyActiveUsersGenerator.stub(:call, ->(_date) { nil }) do
        REDIS.stub(:rpop, nil) do
          result = EventFlushService.flush(aggregate_days: 10)
          assert_equal 7, result[:dates_aggregated].size
        end
      end
    end
  end

  test "flush clamps aggregate_days to minimum of 1" do
    DailyProjectMetricsGenerator.stub(:call, ->(_date) { nil }) do
      ProjectDailyActiveUsersGenerator.stub(:call, ->(_date) { nil }) do
        REDIS.stub(:rpop, nil) do
          result = EventFlushService.flush(aggregate_days: 0)
          assert_equal 1, result[:dates_aggregated].size
        end
      end
    end
  end

  test "flush aggregate_days generates correct date range" do
    aggregated_dates = []

    DailyProjectMetricsGenerator.stub(:call, lambda { |date|
      aggregated_dates << date
    }) do
      ProjectDailyActiveUsersGenerator.stub(:call, ->(_date) { nil }) do
        REDIS.stub(:rpop, nil) do
          result = EventFlushService.flush(aggregate_days: 3)

          assert_equal 3, result[:dates_aggregated].size
          assert_equal Date.today.to_s, result[:dates_aggregated][0]
          assert_equal (Date.today - 1).to_s, result[:dates_aggregated][1]
          assert_equal (Date.today - 2).to_s, result[:dates_aggregated][2]

          # Verify generator received matching dates
          assert_equal [Date.today, Date.today - 1, Date.today - 2], aggregated_dates
        end
      end
    end
  end

  test "flush processes recent events and discards old ones" do
    # Simulate Redis returning events: 1 recent, 1 old
    recent_event = { "created_at" => Time.current.iso8601, "type" => Grovs::Events::VIEW }.to_json
    old_event = { "created_at" => 10.minutes.ago.iso8601, "type" => Grovs::Events::VIEW }.to_json

    call_count = 0
    events = [old_event, recent_event]  # rpop returns from end of list

    rpop_mock = lambda do |_key|
      result = events[call_count]
      call_count += 1
      result
    end

    process_batch_called_with = nil

    DailyProjectMetricsGenerator.stub(:call, ->(_date) { nil }) do
      ProjectDailyActiveUsersGenerator.stub(:call, ->(_date) { nil }) do
        REDIS.stub(:rpop, rpop_mock) do
          # Stub BatchEventProcessorJob to capture what it processes
          fake_job = OpenStruct.new(jid: nil)
          fake_job.define_singleton_method(:send) do |method, batch|
            process_batch_called_with = batch if method == :process_batch
          end

          BatchEventProcessorJob.stub(:new, fake_job) do
            result = EventFlushService.flush(aggregate_days: 1)

            assert_equal 1, result[:processed], "Only recent events should be processed"
            assert_equal 1, result[:discarded], "Old events should be discarded"
          end
        end
      end
    end
  end
end
