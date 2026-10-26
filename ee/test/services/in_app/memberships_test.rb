require "test_helper"
require "sidekiq/testing"

class InAppMembershipsTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
    segment = Segment.create!(project: @project, name: "S", definition: SEGMENT_DEFINITION)
    @campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    Sidekiq::Testing.fake! { @campaign.launch! }
    @manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: @project.id, definition_hash: segment.definition_hash,
                                                list_generation: nil, persons: 0, devices: 0, rows: 0, incomplete: false)
  end

  # Answers like ClickHouse: the ids after the cursor, in order, one page at a time.
  def refresh(ids, page: 5_000, announce: true, fail_after: nil)
    lanes = []
    reader = lambda do |sql, **|
      after = sql[/visitor_id > (\d+)/, 1].to_i
      raise Segments::Busy if fail_after && after >= fail_after

      ids.sort.select { |id| id > after }.first(page).map { |id| { "id" => id } }
    end
    with_page(page) do
      Segments::Results.stub(:for, ->(**kw) { lanes << kw[:lane] && @manifest }) do
        Segments::Runner.stub(:read, reader) { InAppMemberships.refresh(@campaign, announce: announce) }
      end
    end
    lanes
  end

  def stored = SegmentMembership.where(segment_key: @campaign.segment_key).order(:visitor_id).pluck(:visitor_id)

  test "the first run stores every member, in the in_app permit lane" do
    assert_equal [:in_app], refresh([5, 1, 9])
    assert_equal [1, 5, 9], stored
    assert_equal [@project.id], SegmentMembership.distinct.pluck(:project_id)
  end

  test "a later run writes only the differences" do
    refresh([1, 5, 9])
    kept = SegmentMembership.find_by(visitor_id: 5).confirmed_at
    travel(1.hour) { refresh([5, 7]) }
    assert_equal [5, 7], stored
    assert_equal kept, SegmentMembership.find_by(visitor_id: 5).confirmed_at
  end

  test "pages: additions and removals land right whatever the page size" do
    refresh((1..25).to_a, page: 10)
    assert_equal (1..25).to_a, stored
    wanted = [2, 3, 11, 20, 26, 40]
    refresh(wanted, page: 3)
    assert_equal wanted, stored
    refresh([], page: 3)
    assert_equal [], stored
  end

  test "a segment that fills its last page exactly still loses the members beyond it" do
    refresh((1..12).to_a, page: 5)
    refresh((1..10).to_a, page: 5)
    assert_equal (1..10).to_a, stored
  end

  test "only the visitors who entered or left are sent back to sync" do
    refresh([1, 5], announce: false)
    assert_equal "0", InAppStamps.user(1)
    refresh([5, 7])
    assert_equal ["0", true, true], [InAppStamps.user(5), InAppStamps.user(1) != "0", InAppStamps.user(7) != "0"]
  end

  test "another segment's rows are left alone" do
    SegmentMembership.create!(visitor_id: 1, segment_key: "other", project_id: @project.id, confirmed_at: Time.current)
    refresh([])
    assert_equal ["other"], SegmentMembership.pluck(:segment_key)
  end

  test "two runs for one segment never overlap" do
    InAppMemberships.with_lock(@campaign.segment_key) do
      assert_raises(InAppMemberships::Locked) { refresh([1]) }
    end
    refresh([1])
    assert_equal [1], stored
  end

  test "a failed run leaves the stored rows as they were, and frees the lock" do
    refresh([1, 5])
    Segments::Results.stub(:for, ->(**) { raise Segments::Busy }) do
      assert_raises(Segments::Busy) { InAppMemberships.refresh(@campaign) }
    end
    assert_equal [1, 5], stored
    refresh([1])
    assert_equal [1], stored
  end

  test "a read that fails part of the way applies the pages it read, and removes nobody beyond them" do
    refresh([1, 5, 25, 40], announce: false)
    assert_raises(Segments::Busy) { refresh((1..30).to_a - [5, 25], page: 10, fail_after: 20) }
    assert_equal ((1..21).to_a - [5]) + [25, 40], stored
    assert_equal ["0", "0", true], [InAppStamps.user(25), InAppStamps.user(40), InAppStamps.user(5) != "0"]
    refresh([1])
    assert_equal [1], stored
  end

  test "more stored visitors than a page, all gone from the segment, are all removed" do
    refresh((1..23).to_a, page: 5)
    refresh([2], page: 5)
    assert_equal [2], stored
  end

  test "a long refresh renews its lock between pages" do
    renewed = 0
    REDIS.with do |conn|
      conn.stub(:expire, ->(*) { renewed += 1 }) { REDIS.stub(:with, ->(&block) { block.call(conn) }) { refresh((1..12).to_a, page: 5) } }
    end
    assert_equal 3, renewed
  end

  test "two projects with the same rules have their own key, rows and refresh" do
    twin = Segment.create!(project: projects(:two), name: "S", definition: SEGMENT_DEFINITION)
    other = in_app_campaign(projects(:two), audience_type: "segment", segment: twin)
    Sidekiq::Testing.fake! { other.launch! }
    assert_equal @campaign.segment_definition_hash, other.segment_definition_hash
    assert_not_equal @campaign.segment_key, other.segment_key

    refresh([1, 5])
    assert_equal 0, SegmentMembership.where(segment_key: other.segment_key).count
    [@campaign, other].each { |c| c.transition!(from: %w[preparing], to: "live") }
    Sidekiq::Testing.fake! do
      InAppMembershipRefreshJob.jobs.clear
      InAppMembershipRefreshJob.new.perform
      assert_equal [[@campaign.id], [other.id]], InAppMembershipRefreshJob.jobs.pluck("args").sort
    end
  end

  test "cleanup deletes rows no running campaign uses, and keeps the rest" do
    refresh([1, 5])
    @campaign.transition!(from: %w[preparing], to: "live")
    SegmentMembership.create!(visitor_id: 1, segment_key: "orphan", project_id: @project.id, confirmed_at: Time.current)
    InAppMemberships.cleanup
    assert_equal [@campaign.segment_key], SegmentMembership.distinct.pluck(:segment_key)

    Sidekiq::Testing.fake! { @campaign.end! }
    InAppMemberships.cleanup
    assert_equal 0, SegmentMembership.count
  end

  test "cleanup keeps its hands off a segment that is being written" do
    SegmentMembership.create!(visitor_id: 1, segment_key: "orphan", project_id: @project.id, confirmed_at: Time.current)
    InAppMemberships.with_lock("orphan") { InAppMemberships.cleanup }
    assert_equal 1, SegmentMembership.count
  end

  test "a merge moves memberships and view totals to the visitor that survives" do
    from = visitors(:android_visitor)
    to = visitors(:ios_visitor)
    [from, to].each { |visitor| visitor.update_columns(sdk_identifier: nil) }
    live = live_in_app_campaign(@project)
    SegmentMembership.create!(visitor_id: from.id, segment_key: "a", project_id: @project.id, confirmed_at: Time.current)
    SegmentMembership.create!(visitor_id: from.id, segment_key: "b", project_id: @project.id, confirmed_at: Time.current)
    SegmentMembership.create!(visitor_id: to.id, segment_key: "b", project_id: @project.id, confirmed_at: Time.current)
    InAppViews.record(campaign: live, visitor: from, event_id: "e1")
    InAppViews.record(campaign: live, visitor: to, event_id: "e2")
    InAppViews.record(campaign: @campaign, visitor: from, event_id: "e3")

    InAppGateway.merge(from: from, to: to)

    assert_equal [[to.id, "a"], [to.id, "b"]], SegmentMembership.order(:segment_key).pluck(:visitor_id, :segment_key)
    assert_equal({ live.id => 2, @campaign.id => 1 }, InAppViews.totals(project_id: @project.id, visitor: to))
    assert_equal %w[e2 e1], InAppView.find_by(in_app_campaign_id: live.id).recent
    assert_equal 0, InAppView.where(person_key: "v:#{from.id}").count
  end

  test "a merge into a visitor with an identifier lands where sync looks, and tells its devices" do
    from = visitors(:android_visitor)
    to = visitors(:ios_visitor)
    from.update_columns(sdk_identifier: nil)
    to.update_columns(sdk_identifier: "ana")
    capped = live_in_app_campaign(@project, caps: { "lifetime" => 2 })
    InAppViews.record(campaign: capped, visitor: from, event_id: "e1")
    InAppViews.record(campaign: capped, visitor: to, event_id: "e2")
    before = InAppStamps.user(to.id)

    travel(1.second) { InAppGateway.merge(from: from, to: to) }

    assert_equal [["i:ana", 2]], InAppView.where(in_app_campaign_id: capped.id).pluck(:person_key, :total)
    assert_equal({ capped.id => 2 }, InAppViews.totals(project_id: @project.id, visitor: to))
    assert_not_equal before, InAppStamps.user(to.id)
  end

  private

  test "a device is told only once its rows are written" do
    seen = []
    told = ->(ids) { seen << [ids, SegmentMembership.where(segment_key: @campaign.segment_key, visitor_id: ids).count] }
    InAppStamps.stub(:touch_users, told) { refresh([1, 5]) }
    InAppStamps.stub(:touch_users, told) { refresh([5]) }
    assert_equal [[[1, 5], 2], [[1], 0]], seen
  end

  test "the caller claims the rows while the lock is still held, so cleanup cannot take them first" do
    held = nil
    Segments::Results.stub(:for, @manifest) do
      Segments::Runner.stub(:read, [{ "id" => 1 }]) do
        InAppMemberships.refresh(@campaign, announce: false) do
          held = assert_raises(InAppMemberships::Locked) { InAppMemberships.with_lock(@campaign.segment_key) { nil } }
        end
      end
    end
    assert_not_nil held
    InAppMemberships.with_lock(@campaign.segment_key) { nil }
  end

  test "deleting a segment's rows takes them all, whatever else the visitors belong to" do
    with_page(3) do
      (1..10).each do |id|
        %w[a b].each { |key| SegmentMembership.create!(visitor_id: id, segment_key: key, project_id: @project.id, confirmed_at: Time.current) }
      end
      InAppMemberships.delete_all_of(SegmentMembership.where(segment_key: "a"))
      assert_equal({ "b" => 10 }, SegmentMembership.group(:segment_key).count)
      InAppMemberships.delete_all_of(SegmentMembership.where(project_id: @project.id))
      assert_equal 0, SegmentMembership.count
    end
  end

  def with_page(size)
    old = InAppMemberships::PAGE
    InAppMemberships.send(:remove_const, :PAGE)
    InAppMemberships.const_set(:PAGE, size)
    yield
  ensure
    InAppMemberships.send(:remove_const, :PAGE)
    InAppMemberships.const_set(:PAGE, old)
  end
end
