require "test_helper"
require "sidekiq/testing"

class InAppJobsTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
    Sidekiq::Testing.fake!
    [InAppMembershipPopulateJob, InAppMembershipRefreshJob, InAppMembershipCleanupJob].each { |job| job.jobs.clear }
  end

  teardown { Sidekiq::Testing.disable! }

  def segment_campaign(**attrs)
    segment = Segment.create!(project: @project, name: "S#{SecureRandom.hex(2)}", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment, **attrs)
    campaign.launch!
    InAppMembershipPopulateJob.jobs.clear
    campaign
  end

  test "tick starts what is due, ends what has run out, and sends no device back to sync" do
    due = live_in_app_campaign(@project, start_at: 1.hour.from_now)
    later = live_in_app_campaign(@project, start_at: 3.hours.from_now)
    running = live_in_app_campaign(@project, end_at: 90.minutes.from_now)
    paused = live_in_app_campaign(@project, end_at: 90.minutes.from_now)
    paused.transition!(from: %w[live], to: "paused")
    draft = in_app_campaign(@project, end_at: 90.minutes.from_now)
    stamp = InAppStamps.campaigns(@project.id)

    travel(2.hours) { InAppCampaignTickJob.new.perform }

    assert_equal %w[live scheduled ended ended draft], [due, later, running, paused, draft].map { |c| c.reload.status }
    assert_not_nil running.ended_at
    assert_equal stamp, InAppStamps.campaigns(@project.id)
    assert_empty InAppMembershipCleanupJob.jobs
  end

  test "tick does nothing while in-app messages are switched off" do
    due = live_in_app_campaign(@project, end_at: 1.hour.from_now)
    ENV["IN_APP_ENABLED"] = "false"
    travel(2.hours) { InAppCampaignTickJob.new.perform }
    assert_equal "live", due.reload.status
  ensure
    ENV.delete("IN_APP_ENABLED")
  end

  test "tick revives a campaign whose audience job was lost, and gives up after 45 minutes" do
    campaign = segment_campaign
    travel(26.minutes) { InAppCampaignTickJob.new.perform }
    assert_equal [[campaign.id]], InAppMembershipPopulateJob.jobs.pluck("args")
    assert_equal "preparing", campaign.reload.status

    travel(50.minutes) { InAppCampaignTickJob.new.perform }
    assert_equal ["draft", "audience_busy", nil, nil], campaign.reload.values_at(:status, :failure_reason, :launched_at, :segment_key)
  end

  test "tick leaves alone a campaign whose audience job is still trying" do
    campaign = segment_campaign
    travel(14.minutes) do
      InAppMemberships.stub(:refresh, ->(*, **) { raise Clickhouse::Unavailable, "down" }) do
        InAppMembershipPopulateJob.new.perform(campaign.id, 3)
      end
      InAppMembershipPopulateJob.jobs.clear
    end
    travel(30.minutes) { InAppCampaignTickJob.new.perform }
    assert_empty InAppMembershipPopulateJob.jobs
    assert_equal "preparing", campaign.reload.status
  end

  test "populate writes the audience, then the campaign goes live or scheduled" do
    now = segment_campaign
    later = segment_campaign(start_at: 1.day.from_now)
    calls = []
    InAppMemberships.stub(:refresh, ->(campaign, announce:) { calls << [campaign.id, announce] }) do
      [now, later].each { |campaign| InAppMembershipPopulateJob.new.perform(campaign.id) }
    end
    # Both target the same rules, so the second shares the rows the first is already served from.
    assert_equal [[now.id, false], [later.id, true]], calls
    assert_equal %w[live scheduled], [now, later].map { |c| c.reload.status }
  end

  test "going live does not conflict with a composer opened while preparing, and still sends devices to sync" do
    campaign = segment_campaign
    open_in_composer = InAppCampaign.find(campaign.id)
    clear_in_app_stamps(@project)
    InAppMemberships.stub(:refresh, ->(*, **) {}) { InAppMembershipPopulateJob.new.perform(campaign.id) }

    assert_equal "live", campaign.reload.status
    assert_not_equal InAppStamps::NEVER, InAppStamps.campaigns(@project.id)
    assert open_in_composer.update(name: "Renamed")
    assert_equal %w[Renamed live], campaign.reload.values_at(:name, :status)
  end

  test "populate leaves a campaign that is no longer preparing alone" do
    campaign = segment_campaign
    campaign.end!
    InAppMemberships.stub(:refresh, ->(*, **) { flunk "must not refresh" }) { InAppMembershipPopulateJob.new.perform(campaign.id) }
    assert_equal "ended", campaign.reload.status
  end

  test "populate waits for a busy ClickHouse, then returns the campaign to draft with the reason" do
    campaign = segment_campaign
    InAppMemberships.stub(:refresh, ->(*, **) { raise Clickhouse::Unavailable, "down" }) do
      InAppMembershipPopulateJob.new.perform(campaign.id, 0)
      assert_equal [[campaign.id, 1]], InAppMembershipPopulateJob.jobs.pluck("args")
      assert_equal "preparing", campaign.reload.status
      InAppMembershipPopulateJob.new.perform(campaign.id, InAppMembershipPopulateJob::BACKOFF_MINUTES.size)
    end
    assert_equal %w[draft audience_busy], campaign.reload.values_at(:status, :failure_reason)
  end

  test "populate returns a campaign with a broken segment to draft at once" do
    campaign = segment_campaign
    InAppMemberships.stub(:refresh, ->(*, **) { raise Segments::InvalidDefinition, "bad" }) { InAppMembershipPopulateJob.new.perform(campaign.id) }
    assert_equal %w[draft segment_invalid], campaign.reload.values_at(:status, :failure_reason)
    assert_empty InAppMembershipPopulateJob.jobs
  end

  test "the hourly refresh enqueues one job per segment, not per campaign" do
    first = segment_campaign
    first.transition!(from: %w[preparing], to: "live")
    twin = in_app_campaign(@project, audience_type: "segment", segment: first.segment)
    twin.launch!
    twin.transition!(from: %w[preparing], to: "paused")
    other = segment_campaign
    other.transition!(from: %w[preparing], to: "live")
    live_in_app_campaign(@project)
    segment_campaign.end!

    InAppMembershipRefreshJob.new.perform
    assert_equal [[first.id]], InAppMembershipRefreshJob.jobs.pluck("args")
    assert_equal first.segment_key, other.segment_key, "the same rules in one project share one audience"
  end

  test "a refresh that cannot run keeps the rows and raises nothing" do
    campaign = segment_campaign
    campaign.transition!(from: %w[preparing], to: "live")
    InAppMemberships.stub(:refresh, ->(*) { raise Segments::Busy }) do
      assert_nothing_raised { InAppMembershipRefreshJob.new.perform(campaign.id) }
    end
  end

  test "deleting an instance removes every in-app row of its projects" do
    campaign = live_in_app_campaign(@project)
    InAppViews.record(campaign: campaign, visitor: visitors(:ios_visitor), event_id: "e1")
    InAppSetting.for(@project).save!
    SegmentMembership.create!(visitor_id: 1, segment_key: "k", project_id: @project.id, confirmed_at: Time.current)
    keep = live_in_app_campaign(projects(:two))

    DeleteInstanceJob.new.send(:remove_in_app_for_projects, [@project.id])

    assert_equal [keep.id], InAppCampaign.pluck(:id)
    assert_equal [0, 0, 0], [InAppView.count, InAppSetting.count, SegmentMembership.count]
  end

  test "deleting an instance purges custom HTML media files too" do
    campaign = live_in_app_campaign(@project)
    campaign.media.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "p.png", content_type: "image/png")
    blob_id = campaign.media.first.blob_id

    DeleteInstanceJob.new.send(:remove_in_app_for_projects, [@project.id])

    assert_not ActiveStorage::Blob.exists?(blob_id)
    assert_not ActiveStorage::Attachment.exists?(record_type: "InAppCampaign", record_id: campaign.id)
  end

  def purge_sql(segment_id)
    seen = []
    connection = Object.new
    connection.define_singleton_method(:execute) { |sql| seen << sql }
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&block) { block.call(connection) }) do
        Segments::IdentifierList.stub(:with_lock, ->(_id, &block) { block.call }) do
          PurgeSegmentIdentifierGenerationsJob.new.perform(segment_id)
        end
      end
    end
    seen.first
  end

  test "an identifier list a running campaign was launched with is not purged" do
    campaign = segment_campaign
    campaign.update_columns(segment_list_generation: "b" * 32)
    campaign.segment.update_columns(identifier_list_generation: "c" * 32)
    assert_match(/generation NOT IN \('#{'c' * 32}', '#{'b' * 32}'\)/, purge_sql(campaign.segment_id))
  end

  test "an identifier list frozen by a scheduled push or a running journey is not purged" do
    segment = Segment.create!(project: @project, name: "Listed", definition: SEGMENT_DEFINITION, identifier_list_generation: "c" * 32)
    push = PushCampaign.create!(project: @project, name: "Later", title: "Hi", body: "There", audience_type: "segment", recipients: [], segment: segment)
    push.update_columns(status: "scheduled", segment_list_generation: "b" * 32)
    sent = PushCampaign.create!(project: @project, name: "Done", title: "Hi", body: "There", audience_type: "segment", recipients: [], segment: segment)
    sent.update_columns(status: "sent", segment_list_generation: "a" * 32)
    journey = Journey.create!(project: @project, name: "Flow", entry: JourneyFixtures::ADD_TO_CART.deep_dup, first_step: "s1",
                              steps: { "s1" => { "id" => "s1", "type" => "push", "next" => nil }.merge(JourneyFixtures::PUSH) })
    journey.update_columns(status: "live", segment_keys: { "entry" => { "segment_id" => segment.id, "list_generation" => "d" * 32 } })
    finishing = Journey.create!(project: @project, name: "Ending", entry: JourneyFixtures::ADD_TO_CART.deep_dup, first_step: "s1",
                                steps: { "s1" => { "id" => "s1", "type" => "push", "next" => nil }.merge(JourneyFixtures::PUSH) })
    finishing.update_columns(status: "ended", segment_keys: { "f" => { "segment_id" => segment.id, "list_generation" => "e" * 32 } })

    kept = purge_sql(segment.id)[/generation NOT IN \((.*)\)/, 1].scan(/\h{32}/)

    assert_equal %w[b c d e].map { |c| c * 32 }, kept.sort, "the sent push's list may go"
  end
  test "a campaign whose segment was deleted returns to draft and does not stop the ones after it" do
    broken = segment_campaign
    fine = segment_campaign
    broken.update_columns(segment_id: nil)
    travel(50.minutes) { InAppCampaignTickJob.new.perform }
    assert_equal %w[draft draft], [broken.reload.status, fine.reload.status]
  end

  test "a campaign the tick cannot save is logged and the rest are still revived" do
    first = segment_campaign
    second = segment_campaign
    enqueue = ->(id) { id == first.id ? raise(Redis::BaseError) : InAppMembershipPopulateJob.jobs << { "args" => [id] } }
    travel(26.minutes) do
      InAppMembershipPopulateJob.stub(:perform_async, enqueue) { InAppCampaignTickJob.new.perform }
    end
    assert_equal [[second.id]], InAppMembershipPopulateJob.jobs.pluck("args")
  end

  test "a populate retry sends no device back to sync" do
    campaign = segment_campaign
    before = InAppStamps.campaigns(@project.id)
    travel(1.minute) do
      InAppMemberships.stub(:refresh, ->(*, **) { raise Clickhouse::Unavailable, "down" }) do
        InAppMembershipPopulateJob.new.perform(campaign.id, 0)
      end
      assert_equal before, InAppStamps.campaigns(@project.id)
      assert_in_delta Time.current, campaign.reload.updated_at, 1
    end
  end

  test "a segment campaign that ends asks for its own key to be cleaned, not for a scan of every row" do
    campaign = segment_campaign(end_at: 1.hour.from_now)
    key = campaign.segment_key
    campaign.transition!(from: %w[preparing], to: "live")
    travel(2.hours) { InAppCampaignTickJob.new.perform }
    assert_equal [[[key]]], InAppMembershipCleanupJob.jobs.pluck("args")

    SegmentMembership.create!(visitor_id: 1, segment_key: key, project_id: @project.id, confirmed_at: Time.current)
    SegmentMembership.stub(:distinct, -> { flunk "scanned every row" }) { InAppMemberships.cleanup([key]) }
    assert_equal 0, SegmentMembership.where(segment_key: key).count
  end

  test "a long first population keeps the campaign looking worked on" do
    campaign = segment_campaign
    campaign.update_columns(updated_at: 20.minutes.ago)
    manifest = Segments::Results::Manifest.new(result_id: "a" * 32, project_id: @project.id, definition_hash: campaign.segment_definition_hash,
                                               list_generation: nil, persons: 0, devices: 0, rows: 0, incomplete: false)
    Segments::Results.stub(:for, manifest) { Segments::Runner.stub(:read, []) { InAppMemberships.refresh(campaign, announce: false) } }
    assert_in_delta Time.current, campaign.reload.updated_at, 5
  end

  test "tick writes again a stamp that Redis failed to take" do
    campaign = live_in_app_campaign(@project)
    REDIS.with { |conn| conn.set("in_app:campaigns:#{@project.id}", "1") }
    campaign.update_columns(status: "paused", updated_at: Time.current)
    InAppCampaignTickJob.new.perform
    healed = InAppStamps.campaigns(@project.id)
    assert_operator healed.to_i, :>=, (campaign.reload.updated_at.to_f * 1000).to_i

    InAppCampaignTickJob.new.perform
    assert_equal healed, InAppStamps.campaigns(@project.id)
  end

  test "a launch that shares a live campaign's segment tells the devices whose rows it changes" do
    first = segment_campaign
    second = in_app_campaign(@project, audience_type: "segment", segment: first.segment)
    second.launch!
    assert_equal first.segment_key, second.segment_key

    told = []
    InAppMemberships.stub(:refresh, ->(_campaign, announce:) { told << announce }) do
      [first, second].each { |campaign| InAppMembershipPopulateJob.new.perform(campaign.id) }
    end
    assert_equal [false, true], told
  end

  test "updating the audience writes the new members first, then moves the campaign and tells every device" do
    campaign = segment_campaign
    campaign.transition!(from: %w[preparing], to: "live")
    old = campaign.segment_key
    SegmentMembership.create!(visitor_id: 1, segment_key: old, project_id: @project.id, confirmed_at: Time.current)
    changed = SEGMENT_DEFINITION.deep_dup.tap { |d| d["changed"] = true }
    campaign.segment.update_columns(definition: changed, definition_hash: "b" * 64)
    stamp = InAppStamps.campaigns(@project.id)

    seen = []
    write = lambda do |staged, announce:, &claim|
      seen << [staged.segment_key, campaign.reload.segment_key, announce]
      SegmentMembership.create!(visitor_id: 7, segment_key: staged.segment_key, project_id: @project.id, confirmed_at: Time.current)
      claim.call
    end
    travel(1.second) { InAppMemberships.stub(:refresh, write) { InAppAudienceUpdateJob.new.perform(campaign.id) } }

    campaign.reload
    assert_not_equal old, campaign.segment_key
    assert_equal [[campaign.segment_key, old, false]], seen
    assert_equal ["b" * 64, changed], [campaign.segment_definition_hash, campaign.segment_definition]
    assert_not_equal stamp, InAppStamps.campaigns(@project.id)
    assert_equal [[[old]]], InAppMembershipCleanupJob.jobs.pluck("args")

    InAppMemberships.stub(:refresh, ->(*, **) { flunk "nothing changed" }) { InAppAudienceUpdateJob.new.perform(campaign.id) }
  end

  test "an audience update that fails leaves the campaign on its old audience" do
    campaign = segment_campaign
    campaign.transition!(from: %w[preparing], to: "live")
    old = campaign.segment_key
    campaign.segment.update_columns(definition_hash: "c" * 64)
    InAppMemberships.stub(:refresh, ->(*, **) { raise Clickhouse::Unavailable, "down" }) do
      assert_raises(Clickhouse::Unavailable) { InAppAudienceUpdateJob.new.perform(campaign.id) }
    end
    assert_equal old, campaign.reload.segment_key
  end

end
