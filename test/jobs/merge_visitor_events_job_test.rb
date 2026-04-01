require "test_helper"

class MergeVisitorEventsJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events

  setup do
    @job = MergeVisitorEventsJob.new
    @project = projects(:one)
  end

  # --- Guard clauses (verify early return, NOT just "doesn't crash") ---

  test "returns early when from_device not found — no visitors destroyed" do
    assert_no_difference "Visitor.count" do
      @job.perform(999999, devices(:android_device).id, @project.id)
    end
  end

  test "returns early when to_device not found — no visitors destroyed" do
    assert_no_difference "Visitor.count" do
      @job.perform(devices(:ios_device).id, 999999, @project.id)
    end
  end

  test "returns early when from_visitor has no visitor for project — no crash, no side effects" do
    web_device = devices(:web_device)
    assert_nil web_device.visitor_for_project_id(@project.id), "Precondition: web_device has no visitor"

    assert_no_difference "Visitor.count" do
      @job.perform(web_device.id, devices(:android_device).id, @project.id)
    end
  end

  # --- Core merge: events transfer ---

  test "moves all events from from_device to to_device" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    3.times do
      Event.create!(device: from_dev, project: @project, event: "view", platform: "ios")
    end
    to_events_before = Event.where(device_id: to_dev.id).count

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal 0, Event.where(device_id: from_dev.id).count, "All events should leave from_device"
    assert_equal to_events_before + 3, Event.where(device_id: to_dev.id).count, "All events should move to to_device"
    assert Event.where(device_id: to_dev.id).all? { |e| e.platform == "android" }, "Events should inherit to_device platform"
  end

  # --- Core merge: actions transfer ---

  test "transfers actions from from_device to to_device" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    link = links(:basic_link)
    Action.create!(device: from_dev, link: link)

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal 0, Action.where(device_id: from_dev.id).count
    assert Action.where(device_id: to_dev.id, link_id: link.id).exists?
  end

  # --- Core merge: links transfer ---

  test "transfers links from from_visitor to to_visitor" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair

    domain = domains(:one)
    rc = redirect_configs(:one)
    link = Link.create!(domain: domain, redirect_config: rc, path: "merge-link-#{SecureRandom.hex(4)}",
                        title: "Merge Link", visitor: from_vis, generated_from_platform: "ios", active: true, sdk_generated: false)

    perform_merge(from_dev, to_dev, from_vis)

    link.reload
    assert_equal to_vis.id, link.visitor_id, "Link should transfer to to_visitor"
  end

  # --- Visitor daily statistics merge ---

  test "merges visitor daily statistics from from_visitor to to_visitor" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair

    VisitorDailyStatistic.create!(visitor: from_vis, project_id: @project.id, event_date: Date.current, platform: "ios", views: 10, opens: 5)
    VisitorDailyStatistic.create!(visitor: to_vis, project_id: @project.id, event_date: Date.current, platform: "ios", views: 3, opens: 2)

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal 0, VisitorDailyStatistic.where(visitor_id: from_vis.id).count

    merged = VisitorDailyStatistic.find_by(visitor_id: to_vis.id, event_date: Date.current, platform: "ios")
    assert_not_nil merged
    assert_equal 13, merged.views, "Views should be summed (10 + 3)"
    assert_equal 7, merged.opens, "Opens should be summed (5 + 2)"
  end

  # --- VisitorLastVisit transfer ---

  test "transfers VisitorLastVisit when to_visitor has none" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair

    link = links(:basic_link)
    VisitorLastVisit.create!(project: @project, visitor: from_vis, link: link)

    perform_merge(from_dev, to_dev, from_vis)

    assert_nil VisitorLastVisit.find_by(project: @project, visitor_id: from_vis.id)

    to_vlv = VisitorLastVisit.find_by(project: @project, visitor_id: to_vis.id)
    assert_not_nil to_vlv
    assert_equal link.id, to_vlv.link_id
  end

  test "keeps to_visitor VisitorLastVisit when it is more recent" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair

    old_link = links(:basic_link)
    new_link = links(:second_link)

    from_vlv = VisitorLastVisit.create!(project: @project, visitor: from_vis, link: old_link)
    from_vlv.update_column(:updated_at, 2.days.ago)

    VisitorLastVisit.create!(project: @project, visitor: to_vis, link: new_link)

    perform_merge(from_dev, to_dev, from_vis)

    to_vlv = VisitorLastVisit.find_by(project: @project, visitor_id: to_vis.id)
    assert_equal new_link.id, to_vlv.link_id, "Should keep to_visitor's more recent link"
  end

  # --- Inviter transfer ---

  test "transfers inviter_id from from_visitor to to_visitor when to has none" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair(from_attrs: { inviter_id: 42 }, to_attrs: { inviter_id: nil })

    perform_merge(from_dev, to_dev, from_vis)

    to_vis_after = Visitor.find_by(device: to_dev, project: @project)
    assert_equal 42, to_vis_after.inviter_id
  end

  test "does not overwrite to_visitor inviter_id when it already has one" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair(from_attrs: { inviter_id: 99 }, to_attrs: { inviter_id: 77 })

    perform_merge(from_dev, to_dev, from_vis)

    to_vis_after = Visitor.find_by(device: to_dev, project: @project)
    assert_equal 77, to_vis_after.inviter_id, "Should NOT overwrite existing inviter"
  end

  # --- Visitor destruction ---

  test "destroys from_visitor after merge" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    perform_merge(from_dev, to_dev, from_vis)

    assert_nil Visitor.find_by(id: from_vis.id), "from_visitor should be destroyed"
  end

  # --- InstalledApp creation ---

  test "creates InstalledApp records for both devices" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    perform_merge(from_dev, to_dev, from_vis)

    assert InstalledApp.exists?(device_id: from_dev.id, project_id: @project.id)
    assert InstalledApp.exists?(device_id: to_dev.id, project_id: @project.id)
  end

  private

  # Create a pair of devices+visitors for merge testing. Uses randomized IPs
  # to avoid Redis fingerprint cache collisions between parallel test processes.
  def create_merge_pair(from_attrs: {}, to_attrs: {})
    hex = SecureRandom.hex(4)
    from_dev = Device.create!(
      user_agent: "MergeFrom/#{hex}",
      ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      platform: "ios"
    )
    to_dev = Device.create!(
      user_agent: "MergeTo/#{hex}",
      ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      platform: "android"
    )
    from_vis = Visitor.create!({ device: from_dev, project: @project }.merge(from_attrs))
    to_vis = Visitor.create!({ device: to_dev, project: @project }.merge(to_attrs))

    [from_dev, to_dev, from_vis, to_vis]
  end

  # Run the merge job with Visitor Redis cache bypassed.
  # visitor_for_project_id uses redis_find_by_multiple_conditions which
  # returns stale results in parallel tests (10 processes share one Redis).
  # We bypass the cache layer so lookups hit the DB directly — the merge
  # logic itself (event/action/stat transfer, visitor destruction) is still
  # fully exercised against real data.
  def perform_merge(from_dev, to_dev, _from_vis)
    db_lookup = lambda { |conditions, **kwargs|
      query = Visitor.all
      query = query.includes(kwargs[:includes]) if kwargs[:includes]
      query.find_by(conditions.is_a?(Hash) ? conditions : { conditions[0] => conditions[1] })
    }

    Visitor.stub(:redis_find_by_multiple_conditions, db_lookup) do
      @job.perform(from_dev.id, to_dev.id, @project.id)
    end
  end
end
