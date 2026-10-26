require "test_helper"
require "sidekiq/testing"

class PushCampaignDeliverJobTest < ActiveSupport::TestCase
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  setup do
    devices(:ios_device).update_columns(push_token: "tok")
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    PushCampaigns::Audience.freeze!(@campaign)
    @apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
  end

  teardown do
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
    REDIS.with do |c|
      c.del(PushCampaignDeliverJob.slot_key(@campaign.id, 0), PushCampaignDeliverJob.slot_key(@campaign.id, 4), PushCampaignDeliverJob::WAITING_KEY,
            "push:deliver:yield:999999:0",
            *Array.new(PushCampaignDeliverJob::DEDICATED_MAX_WORKERS) { |i| PushCampaignDeliverJob.worker_key(i) })
    end
  end

  def with_endless_slices
    original = PushCampaigns::Deliverer.instance_method(:deliver_slice)
    PushCampaigns::Deliverer.define_method(:deliver_slice) { |**| 1 }
    yield
  ensure
    PushCampaigns::Deliverer.define_method(:deliver_slice, original)
  end

  test "drains the campaign, finishes it and audits the send" do
    EnterpriseSubscription.create!(instance: instances(:one), active: true, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 100)
    RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(@campaign.id, 0) }
    assert_equal "sent", @campaign.reload.status
    assert_equal 1, AuditEvent.where(action: "push_campaign.sent").count
    assert_equal 1, Rpush::Apnsp8::Notification.count
    assert_nil REDIS.with { |c| c.get(PushCampaignDeliverJob.slot_key(@campaign.id, 0)) }, "slot released"
  end

  test "a held slot makes the job exit without touching rows" do
    REDIS.with { |c| c.set(PushCampaignDeliverJob.slot_key(@campaign.id, 0), "other", ex: 60) }
    PushCampaignDeliverJob.new.perform(@campaign.id, 0)
    assert_equal "sending", @campaign.reload.status
    assert_equal "other", REDIS.with { |c| c.get(PushCampaignDeliverJob.slot_key(@campaign.id, 0)) }
  end

  test "re-enqueues itself when the deadline passes with work left" do
    original = PushCampaigns::Deliverer.instance_method(:deliver_slice)
    PushCampaigns::Deliverer.define_method(:deliver_slice) { |**| 1 }
    with_const(PushCampaignDeliverJob, :LOOP_SECONDS, 0) do
      Sidekiq::Testing.fake! do
        PushCampaignDeliverJob.clear
        PushCampaignDeliverJob.new.perform(@campaign.id, 0)
        assert_equal [[@campaign.id, 0]], PushCampaignDeliverJob.jobs.map { |j| j["args"] }
      end
    end
  ensure
    PushCampaigns::Deliverer.define_method(:deliver_slice, original)
  end

  test "a throttled slice pauses and keeps the campaign sending" do
    original = PushCampaigns::Deliverer.instance_method(:deliver_slice)
    PushCampaigns::Deliverer.define_method(:deliver_slice) { |**| :throttled }
    with_const(PushCampaignDeliverJob, :LOOP_SECONDS, 0.3) do
      with_const(PushCampaignDeliverJob, :THROTTLE_PAUSE, 0.1) do
        Sidekiq::Testing.fake! do
          PushCampaignDeliverJob.clear
          PushCampaignDeliverJob.new.perform(@campaign.id, 0)
          assert_equal 1, PushCampaignDeliverJob.jobs.size, "re-enqueued to try again"
        end
      end
    end
    assert_equal "sending", @campaign.reload.status
  ensure
    PushCampaigns::Deliverer.define_method(:deliver_slice, original)
  end

  test "with every worker busy the campaign waits its turn without delivering" do
    PushCampaignDeliverJob.stub(:max_workers, 1) do
      REDIS.with { |c| c.set(PushCampaignDeliverJob.worker_key(0), "other", ex: 60) }
      Sidekiq::Testing.fake! do
        PushCampaignDeliverJob.clear
        RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(@campaign.id, 0) }
        job = PushCampaignDeliverJob.jobs.first
        assert job["at"], "retried later, not straight away"
        marker = job["args"].last
        assert_equal marker, REDIS.with { |c| c.get(PushCampaignDeliverJob.slot_key(@campaign.id, 0)) }, "slot kept for the retry"

        PushCampaignDeliverJob.clear
        PushCampaignDeliverJob.new.perform(@campaign.id, 0)
        assert_empty PushCampaignDeliverJob.jobs, "the tick's copy of a waiting slot exits instead of piling up"

        REDIS.with { |c| c.del(PushCampaignDeliverJob.worker_key(0)) }
        RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(@campaign.id, 0, marker) }
      end
      assert_equal 1, Rpush::Apnsp8::Notification.count, "the waiting job resumes with its own marker"
      assert_empty REDIS.with { |c| c.zrange(PushCampaignDeliverJob::WAITING_KEY, 0, -1) }
    end
  end

  test "a process never gives loops its last threads, whatever leases are free" do
    PushCampaignDeliverJob.stub(:local_limit, 1) do
      PushCampaignDeliverJob.local_loops.increment
      Sidekiq::Testing.fake! do
        PushCampaignDeliverJob.clear
        PushCampaignDeliverJob.new.perform(@campaign.id, 0)
        assert PushCampaignDeliverJob.jobs.first["at"], "waits like a job without a lease"
      end
      assert_equal 1, PushCampaignDeliverJob.local_loops.value
      assert_nil REDIS.with { |c| c.get(PushCampaignDeliverJob.worker_key(0)) }, "no lease taken"
    ensure
      PushCampaignDeliverJob.local_loops.decrement
    end
    marker = REDIS.with { |c| c.get(PushCampaignDeliverJob.slot_key(@campaign.id, 0)) }
    RpushService.stub(:app_for_platform, @apns) { PushCampaignDeliverJob.new.perform(@campaign.id, 0, marker) }
    assert_equal 0, PushCampaignDeliverJob.local_loops.value, "released after the loop"
  end

  test "a Redis error while leasing gives the process's loop slot back" do
    job = PushCampaignDeliverJob.new
    job.stub(:lease_worker, ->(_) { raise Redis::CannotConnectError }) do
      assert_raises(Redis::CannotConnectError) { job.perform(@campaign.id, 0) }
    end
    assert_equal 0, PushCampaignDeliverJob.local_loops.value
  end

  test "only one running loop gives up its worker per waiting campaign" do
    REDIS.with do |c|
      c.del("push:deliver:yield:999999:0")
      c.zadd(PushCampaignDeliverJob::WAITING_KEY, Time.now.to_f, "999999:0")
    end
    job = PushCampaignDeliverJob.new
    assert job.send(:others_waiting?, @campaign.id), "the first loop yields"
    assert_not job.send(:others_waiting?, @campaign.id), "the others keep their workers"
  ensure
    REDIS.with { |c| c.del("push:deliver:yield:999999:0") }
  end

  test "a tick copy that finds the slot held leaves the waiter's entry alone" do
    REDIS.with do |c|
      c.set(PushCampaignDeliverJob.slot_key(@campaign.id, 0), "waiter", ex: 60)
      c.zadd(PushCampaignDeliverJob::WAITING_KEY, Time.now.to_f, "#{@campaign.id}:0")
    end
    PushCampaignDeliverJob.new.perform(@campaign.id, 0)
    assert_equal ["#{@campaign.id}:0"], REDIS.with { |c| c.zrange(PushCampaignDeliverJob::WAITING_KEY, 0, -1) }
  end

  test "a slot beyond the worker cap exits, so a shared worker never polls for it" do
    PushCampaignDeliverJob.stub(:max_workers, 4) do
      Sidekiq::Testing.fake! do
        PushCampaignDeliverJob.clear
        PushCampaignDeliverJob.new.perform(@campaign.id, 4)
        assert_empty PushCampaignDeliverJob.jobs
      end
    end
    assert_nil REDIS.with { |c| c.get(PushCampaignDeliverJob.slot_key(@campaign.id, 4)) }
  end

  test "a loop gives its worker up after its turn when another campaign is waiting" do
    REDIS.with do |c|
      c.zadd(PushCampaignDeliverJob::WAITING_KEY, Time.now.to_f, "999999:0")
      c.del("push:deliver:yield:999999:0")
    end
    with_endless_slices do
      with_const(PushCampaignDeliverJob, :TURN_SECONDS, 0) do
        Sidekiq::Testing.fake! do
          PushCampaignDeliverJob.clear
          PushCampaignDeliverJob.new.perform(@campaign.id, 0)
          assert PushCampaignDeliverJob.jobs.first["at"], "resumes after the waiter had a chance"
        end
      end
    end
    assert_nil REDIS.with { |c| c.get(PushCampaignDeliverJob.worker_key(0)) }, "worker released"
  end

  test "with nobody waiting a loop keeps its worker for the whole loop" do
    with_endless_slices do
      with_const(PushCampaignDeliverJob, :TURN_SECONDS, 0) do
        with_const(PushCampaignDeliverJob, :LOOP_SECONDS, 0.2) do
          Sidekiq::Testing.fake! do
            PushCampaignDeliverJob.clear
            PushCampaignDeliverJob.new.perform(@campaign.id, 0)
            assert_nil PushCampaignDeliverJob.jobs.first["at"], "continues straight away"
          end
        end
      end
    end
  end

  test "the cap is 4 on a shared worker, 16 on a push-only one, and the env wins" do
    saved = ENV.delete("PUSH_DELIVERY_MAX_WORKERS")
    PushCampaignDeliverJob.stub(:dedicated_worker?, false) { assert_equal 4, PushCampaignDeliverJob.max_workers }
    PushCampaignDeliverJob.stub(:dedicated_worker?, true) { assert_equal 16, PushCampaignDeliverJob.max_workers }
    ENV["PUSH_DELIVERY_MAX_WORKERS"] = "7"
    assert_equal 7, PushCampaignDeliverJob.max_workers
  ensure
    saved.nil? ? ENV.delete("PUSH_DELIVERY_MAX_WORKERS") : ENV["PUSH_DELIVERY_MAX_WORKERS"] = saved
  end

  test "a campaign that is not sending is ignored" do
    @campaign.update!(status: "draft")
    PushCampaignDeliverJob.new.perform(@campaign.id, 0)
    assert_equal 0, Rpush::Apnsp8::Notification.count
  end
end
