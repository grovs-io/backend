require "test_helper"

# Through the job itself, with its own transaction and statement timeout, not through the service it calls.
class InAppMergeTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
    @campaign = live_in_app_campaign(@project, caps: { "lifetime" => 3 })
  end

  def device(label, platform)
    Device.create!(user_agent: "#{label}/#{SecureRandom.hex(4)}", ip: "172.20.1.#{rand(256)}", remote_ip: "172.20.2.#{rand(256)}",
                   platform: platform)
  end

  def pair(to_identifier: nil)
    from = Visitor.create!(device: device("From", "ios"), project: @project)
    to = Visitor.create!(device: device("To", "android"), project: @project, sdk_identifier: to_identifier)
    [from, to]
  end

  def merge(from, to) = MergeVisitorEventsJob.new.perform(from.device_id, to.device_id, @project.id)
  def views = InAppView.where(in_app_campaign_id: @campaign.id).order(:person_key).pluck(:person_key, :total)

  test "an anonymous visitor's views join the survivor's, and the survivor is told to sync" do
    from, to = pair
    2.times { |i| InAppViews.record(campaign: @campaign, visitor: from, event_id: "a#{i}") }
    InAppViews.record(campaign: @campaign, visitor: to, event_id: "b")
    SegmentMembership.create!(visitor_id: from.id, segment_key: "k", project_id: @project.id, confirmed_at: Time.current)
    before = InAppStamps.user(to.id)

    merge(from, to)

    assert_equal [["v:#{to.id}", 3]], views
    assert_equal [to.id], SegmentMembership.where(segment_key: "k").pluck(:visitor_id)
    assert_not_equal before, InAppStamps.user(to.id)
  end

  test "the views go to the survivor's identifier when it has one" do
    from, to = pair(to_identifier: "ana")
    InAppViews.record(campaign: @campaign, visitor: from, event_id: "a")
    InAppViews.record(campaign: @campaign, visitor: to, event_id: "b")

    merge(from, to)

    assert_equal [["i:ana", 2]], views
  end

  test "a merge with nothing to move leaves the views alone" do
    from, to = pair
    InAppViews.record(campaign: @campaign, visitor: to, event_id: "b")
    merge(from, to)
    assert_equal [["v:#{to.id}", 1]], views
  end
end
