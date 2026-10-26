require "test_helper"
require "sidekiq/testing"

class Experiments::HoldsAndDeferralsTest < ActiveSupport::TestCase
  include ConstStubHelper
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  B = { "id" => "b", "title" => "Hey", "body" => "Look" }.freeze

  class DownRedis
    def with = raise(Redis::CannotConnectError, "down")
  end

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    @bo = visitors(:android_visitor)
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    REDIS.with { |c| c.keys("in_app:held:*").each { |k| c.del(k) } }
  end

  teardown do
    Sidekiq::Testing.disable!
    REDIS.with { |c| c.keys("in_app:held:*").each { |k| c.del(k) } }
  end

  def logged(&)
    calls = []
    EventIngestionService.stub(:log_async, ->(*args, **kw) { calls << [args[0], args[2].id, args[3], kw[:event_name]] }, &)
    calls
  end

  def redis_down(&) = with_const(Object, :REDIS, DownRedis.new, &)

  def waiting_campaign
    c = PushCampaign.create!(project: @project, name: "n", title: "t", body: "b", status: "draft", audience_type: "visitors", recipients: [@ana.uuid],
                             variants: [B], test_share: 10, winner_after_minutes: 30)
    c.update_columns(status: "sent", waiting: 1, winner_due_at: 1.minute.ago, started_at: 1.hour.ago)
    PushDelivery.create!(push_campaign: c, visitor: @ana, device_id: @ana.device_id, platform: "ios", status: "waiting")
    c
  end

  test "a hold is pending once a day per person and campaign; marking one leaves the others pending" do
    assert Experiments::Held.pending?(@project, @ana, campaign: "c1")
    assert Experiments::Held.mark(@project, @ana, campaign: "c1")
    assert_not Experiments::Held.pending?(@project, @ana, campaign: "c1")
    assert_not Experiments::Held.mark(@project, @ana, campaign: "c1"), "a second mark the same day is no new hold"
    assert Experiments::Held.pending?(@project, @ana, campaign: "c2")
    assert Experiments::Held.pending?(@project, @bo, campaign: "c1")
    assert Experiments::Held.pending?(@project, @ana), "the project hold is its own"
    assert_in_delta Experiments::Held::DAY, REDIS.with { |r| r.ttl(Experiments::Held.key(@project, @ana, "c1")) }, 2
  end

  test "the hold event is written once a day: per campaign with its id, else for the project" do
    calls = logged do
      2.times { Experiments::Held.in_app(project: @project, device: @ana.device, visitor: @ana, campaign: "c1") }
      Experiments::Held.in_app(project: @project, device: @ana.device, visitor: @ana)
      Experiments::Held.in_app(project: @project, device: nil, visitor: @bo)
    end
    device = @ana.device_id
    assert_equal [["custom", device, { "campaign_id" => "c1", "scope" => "campaign" }, "in_app_held"],
                  ["custom", device, { "scope" => "project" }, "in_app_held"]], calls
    assert Experiments::Held.pending?(@project, @bo), "a person without a device is never marked"
  end

  test "with Redis down nothing is held: no event, no mark, and pending says no so the caller does no work" do
    calls = logged do
      redis_down do
        assert_not Experiments::Held.pending?(@project, @ana, campaign: "c1")
        assert_nil Experiments::Held.mark(@project, @ana, campaign: "c1")
        assert_nothing_raised { Experiments::Held.in_app(project: @project, device: @ana.device, visitor: @ana, campaign: "c1") }
      end
    end
    assert_empty calls
    assert Experiments::Held.pending?(@project, @ana, campaign: "c1")
  end

  test "a winner timer with ClickHouse down defers: nobody is sent, the campaign keeps waiting, and a later run sends" do
    c = waiting_campaign
    Experiments::Report.stub(:push, ->(*, **) { raise Clickhouse::Unavailable, "experiment report" }) do
      assert_equal false, Experiments::Winner.send_to_rest(c)
    end
    c.reload
    assert_equal ["sent", 1, nil], [c.status, c.waiting, c.winner]
    assert_equal ["waiting"], c.deliveries.pluck(:status)
    assert_empty PushCampaignDeliverJob.jobs
    assert_equal 0, AuditEvent.where(action: "push_campaign.winner_sent").count

    n = Experiments::Report::MIN_PEOPLE
    groups = [{ "id" => "a", "exposed" => n, "click_rate" => 0.1 }, { "id" => "b", "exposed" => n, "click_rate" => 0.3 }]
    Experiments::Report.stub(:push, ->(*, **) { { "groups" => groups } }) { assert Experiments::Winner.send_to_rest(c) }
    assert_equal ["sending", "b", 0], [c.reload.status, c.winner, c.waiting]
    assert_equal PushCampaignEvaluateJob::PARALLELISM, PushCampaignDeliverJob.jobs.size
  end

  test "an experiment report refuses dates it cannot read, and an end before the start" do
    c = live_in_app_campaign(@project, control_group: 10)
    error = assert_raises(InAppReport::Invalid) { Experiments::Report.in_app(c, from: "2026-13-01", to: "2026-10-01") }
    assert_equal "from and to must be dates such as 2026-10-01", error.message
    error = assert_raises(InAppReport::Invalid) { Experiments::Report.in_app(c, from: "2026-10-02", to: "2026-10-01") }
    assert_equal "the range must be 1 to #{InAppReport::MAX_DAYS} days", error.message
  end

  test "an experiment report turns a ClickHouse outage into Unavailable and lets a broken query surface" do
    c = live_in_app_campaign(@project, control_group: 10)
    read = ->(error) { Clickhouse.stub(:with, ->(*) { raise error }) { Experiments::Report.in_app(c, from: Date.current.iso8601, to: Date.current.iso8601) } }
    assert_raises(Clickhouse::Unavailable) { read.call(ClickHouse::Client::DatabaseError.new("Code: 241. DB::Exception: Memory limit (total) exceeded")) }
    assert_raises(Clickhouse::Unavailable) { read.call(ClickHouse::Client::DatabaseError.new("<html>502 Bad Gateway</html>")) }
    broken = ClickHouse::Client::DatabaseError.new("Code: 62. DB::Exception: Syntax error")
    assert_same broken, assert_raises(ClickHouse::Client::DatabaseError) { read.call(broken) }
  end
end
