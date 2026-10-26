require "test_helper"

class InAppSyncHoldsTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
  end

  teardown { REDIS.with { |c| c.keys("in_app:held:*").each { |k| c.del(k) } } }

  # A visitor whose bucket under `salt` is below `pct`, so they fall in that control group.
  def held_visitor(salt, pct)
    50.times do
      v = Visitor.create!(project: @project, device: devices(:web_device))
      return v if Experiments::Bucket.of(salt.call(v), v.id) < pct
    end
    flunk "no visitor in the control"
  end

  def sync(visitor, held) = InAppSync.call(project: @project, visitor: visitor, held: held, device: visitor.device)
  def stamps(visitor) = InAppStamps.for(@project.id, visitor.id)
  def next_day(visitor) = REDIS.with { |c| c.keys("in_app:held:#{@project.id}:#{visitor.id}:*").each { |k| c.del(k) } }

  def holds(&)
    calls = []
    EventIngestionService.stub(:log_async, ->(*args, **kw) { calls << [args[2].id, args[3], kw[:event_name]] }, &)
    calls
  end

  test "a held person syncing unchanged is still counted once a day in the campaign's control" do
    campaign = live_in_app_campaign(@project, control_group: 50)
    v = held_visitor(->(_) { campaign.hashid }, 50)
    first = holds { assert_empty sync(v, nil)["campaigns"] }
    assert_equal [[v.device_id, { "campaign_id" => campaign.hashid, "scope" => "campaign" }, "in_app_held"]], first

    next_day(v)
    again = holds do
      assert sync(v, stamps(v))["unchanged"]
      assert sync(v, stamps(v))["unchanged"]
    end
    assert_equal first, again, "recorded on the first unchanged sync of the day, not on the second"
  end

  test "a held person outside the campaign's segment is not counted, and the segment is not asked again that day" do
    segment = Segment.create!(project: @project, name: "VIP", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment, control_group: 50)
    campaign.launch!
    campaign.update_columns(status: "live")
    v = held_visitor(->(_) { campaign.hashid }, 50)
    clear_in_app_stamps(@project)

    asked = ->(&run) { [].tap { |sql| ActiveSupport::Notifications.subscribed(->(*, p) { sql << p[:sql] if p[:sql].include?("segment_memberships") }, "sql.active_record", &run) } }
    calls = []
    first = asked.call { calls = holds { assert sync(v, stamps(v))["unchanged"] } }
    assert_not_empty first, "the first unchanged sync of the day checks the audience"
    assert_empty calls
    assert_not Experiments::Held.pending?(@project, v, campaign: campaign.hashid), "checked for today"
    assert_empty asked.call { sync(v, stamps(v)) }
  end

  test "a person in the project-wide control syncing unchanged is counted once a day for the project" do
    live_in_app_campaign(@project)
    v = held_visitor(->(_) { @project.hashid }, 20)
    InAppSetting.create!(project: @project, control_group: 20)
    calls = holds do
      assert sync(v, stamps(v))["unchanged"]
      assert sync(v, stamps(v))["unchanged"]
    end
    assert_equal [[v.device_id, { "scope" => "project" }, "in_app_held"]], calls
  end

  test "a failed hold never fails the sync" do
    campaign = live_in_app_campaign(@project, control_group: 50)
    v = held_visitor(->(_) { campaign.hashid }, 50)
    Experiments::Held.stub(:pending?, ->(*, **) { raise ActiveRecord::ConnectionTimeoutError }) do
      assert_equal({ "unchanged" => true }, sync(v, stamps(v)).slice("unchanged"))
    end
  end

  test "a cache store that is down still serves the person's messages from Postgres" do
    campaign = live_in_app_campaign(@project)
    v = visitors(:ios_visitor)
    Rails.cache.stub(:fetch, ->(*, **) { raise Redis::CannotConnectError, "down" }) do
      assert_equal [campaign.hashid], sync(v, nil)["campaigns"].pluck("id")
    end
  end
end
