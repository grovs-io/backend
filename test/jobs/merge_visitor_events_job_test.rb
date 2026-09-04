require "test_helper"

class MergeVisitorEventsJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events

  setup do
    @job = MergeVisitorEventsJob.new
    @project = projects(:one)
  end

  # Breadcrumb cleanup is global — see test_helper.rb setup

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

  test "enqueues the ClickHouse fold job (merged->survivor) instead of deleting canonical data" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    enqueued = nil
    # The CH fold is a separate retryable job now (durable alias via Sidekiq retry).
    # The merge's contract is to ENQUEUE it; record_merge/mark_dirty behavior is
    # asserted in MergeVisitorClickhouseFoldJobTest.
    MergeVisitorClickhouseFoldJob.stub(:perform_async, ->(pid, from, to) { enqueued = [pid, from, to] }) do
      perform_merge(from_dev, to_dev, from_vis)
    end
    assert_equal [@project.id, from_vis.id, to_vis.id], enqueued,
      "merge must enqueue the fold job to alias the merged-away visitor to the survivor"
    # delete_visitor was removed in Phase 4 — canonical history is never deleted on merge.
    assert_not ClickhouseDeleteService.respond_to?(:delete_visitor),
      "merge must NOT delete canonical visitor data anymore"
  end

  test "a failed fold enqueue folds inline instead of stranding the alias (no whole-job retry)" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    inline = nil
    # Enqueue blows up (Redis blip). It must NOT escape merge! (a retry would early-return with
    # from_visitor gone and never re-enqueue) — instead the fold runs inline.
    MergeVisitorClickhouseFoldJob.stub(:perform_async, ->(*) { raise Redis::BaseError, "redis down" }) do
      ClickhouseIdentityMapService.stub(:record_merge, ->(pid, from, to) { inline = [pid, from, to] }) do
        ClickhouseRollupRebuildService.stub(:mark_dirty_for_visitor, ->(*) {}) do
          assert_nothing_raised { perform_merge(from_dev, to_dev, from_vis) }
        end
      end
    end
    assert_equal [@project.id, from_vis.id, to_vis.id], inline,
      "a failed enqueue must fall back to an inline fold so the alias is still recorded"
    assert_not Visitor.exists?(id: from_vis.id), "the PG merge must still be committed"
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

  test "leaves visitor daily statistics untouched when PG shadow writes are off" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    stat = VisitorDailyStatistic.create!(visitor: from_vis, project_id: @project.id,
                                         event_date: Date.current, platform: "ios", views: 10)
    invited_dev = create_device("Invited")
    invited = Visitor.create!(device: invited_dev, project: @project, inviter_id: from_vis.id)
    invited_stat = VisitorDailyStatistic.create!(visitor: invited, project_id: @project.id,
                                                 event_date: Date.current, platform: "ios",
                                                 invited_by_id: from_vis.id, installs: 1)

    enqueued = nil
    ENV["PG_SHADOW_WRITES"] = "false"
    begin
      MergeVisitorClickhouseFoldJob.stub(:perform_async, ->(pid, from, to) { enqueued = [pid, from, to] }) do
        perform_merge(from_dev, to_dev, from_vis)
      end
    ensure
      ENV.delete("PG_SHADOW_WRITES")
    end

    assert_equal [@project.id, from_vis.id, to_vis.id], enqueued, "the CH fold stays unconditional"
    assert_equal from_vis.id, stat.reload.visitor_id
    assert_equal from_vis.id, invited_stat.reload.invited_by_id
    # Visitor.inviter_id is canonical data, not a stat — it must still be repointed.
    assert_equal to_vis.id, invited.reload.inviter_id
  end

  test "merges cross-platform visitor daily statistics as separate rows" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair

    date = Date.current

    VisitorDailyStatistic.create!(visitor: from_vis, project_id: @project.id, event_date: date, platform: "ios", views: 10)
    VisitorDailyStatistic.create!(visitor: from_vis, project_id: @project.id, event_date: date, platform: "android", views: 20)
    VisitorDailyStatistic.create!(visitor: to_vis, project_id: @project.id, event_date: date, platform: "ios", views: 5)

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal 0, VisitorDailyStatistic.where(visitor_id: from_vis.id).count

    ios_stat = VisitorDailyStatistic.find_by(visitor_id: to_vis.id, event_date: date, platform: "ios")
    android_stat = VisitorDailyStatistic.find_by(visitor_id: to_vis.id, event_date: date, platform: "android")

    assert_not_nil ios_stat
    assert_not_nil android_stat, "Android stat should remain as separate row"
    assert_equal 15, ios_stat.views, "iOS views should be summed (10 + 5)"
    assert_equal 20, android_stat.views, "Android views should be inserted as-is"
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

  # --- Referral attribution repointing ---

  test "repoints other visitors' referral attribution to to_visitor" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    invited_dev = create_device("Invited")
    invited = Visitor.create!(device: invited_dev, project: @project, inviter_id: from_vis.id)
    vds = VisitorDailyStatistic.create!(visitor: invited, project_id: @project.id,
                                        event_date: Date.current, platform: "ios",
                                        invited_by_id: from_vis.id, installs: 1)

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal to_vis.id, invited.reload.inviter_id
    assert_equal to_vis.id, vds.reload.invited_by_id
  end

  test "merging the inviter into an invited visitor does not create a self-referral" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    to_vis.update_column(:inviter_id, from_vis.id)
    vds = VisitorDailyStatistic.create!(visitor: to_vis, project_id: @project.id,
                                        event_date: Date.current, platform: "android",
                                        invited_by_id: from_vis.id, installs: 1)

    perform_merge(from_dev, to_dev, from_vis)

    assert_nil to_vis.reload.inviter_id, "merge target must not become its own inviter"
    assert_nil vds.reload.invited_by_id, "merge target's stats must not be self-attributed"
  end

  test "merging an invited visitor into its inviter does not adopt a self-referral" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    from_vis.update_column(:inviter_id, to_vis.id)

    perform_merge(from_dev, to_dev, from_vis)

    assert_nil to_vis.reload.inviter_id, "merge target must not adopt itself as inviter"
  end

  test "repoints stats rows whose visitor's inviter diverged from invited_by_id" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    other_dev = create_device("Diverged")
    other = Visitor.create!(device: other_dev, project: @project, inviter_id: nil)
    vds = VisitorDailyStatistic.create!(visitor: other, project_id: @project.id,
                                        event_date: Date.current, platform: "ios",
                                        invited_by_id: from_vis.id, installs: 1)

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal to_vis.id, vds.reload.invited_by_id,
      "stats stamped with the deleted inviter must repoint, not dangle"
  end

  # --- Device-merge breadcrumb ---

  test "writes the device-merge breadcrumb after a successful merge" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    perform_merge(from_dev, to_dev, from_vis)

    assert_equal to_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev))
  ensure
    REDIS.del(breadcrumb_key(from_dev)) if from_dev
  end

  test "a reverse merge within the breadcrumb window is a no-op, not a ping-pong" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair
    perform_merge(from_dev, to_dev, from_vis) # A→B

    @job.perform(to_dev.id, from_dev.id, @project.id) # B→A redirects to B→B → no-op

    assert Visitor.exists?(device: to_dev, project: @project), "merged identity must stay on the target"
    assert_equal to_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev)), "A→B breadcrumb must survive"
    assert_nil REDIS.get(breadcrumb_key(to_dev)), "no reverse breadcrumb may be written"
  end

  test "breadcrumb and CH fold survive a cache invalidation failure" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    fold_calls = []
    @job.stub(:fold_visitor_into_survivor_in_clickhouse, ->(*args) { fold_calls << args }) do
      REDIS.stub(:del, ->(*_keys) { raise Redis::BaseError, "cache del boom" }) do
        assert_nothing_raised { perform_merge(from_dev, to_dev, from_vis) }
      end
    end

    assert_nil Visitor.find_by(id: from_vis.id), "merge must have committed"
    assert_equal to_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev)),
      "breadcrumb is correctness-critical and must be written before cache invalidation"
    assert_equal 1, fold_calls.size, "CH fold must still run after a cache invalidation failure"
  ensure
    REDIS.del(breadcrumb_key(from_dev)) if from_dev
  end

  test "breadcrumb write retries through a transient Redis blip without failing the job" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    orig_set = REDIS.method(:set)
    failures = 0
    fold_ran = false
    @job.stub(:fold_visitor_into_survivor_in_clickhouse, ->(*) { fold_ran = true }) do
      REDIS.stub(:set, lambda { |key, *args, **kw|
        if key.start_with?(BatchEventProcessorJob::MERGED_DEVICE_PREFIX) && (failures += 1) <= 2
          raise Redis::BaseError, "transient blip"
        end

        orig_set.call(key, *args, **kw)
      }) do
        perform_merge(from_dev, to_dev, from_vis)
      end
    end

    assert_equal to_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev)),
      "breadcrumb must land after transient failures"
    assert fold_ran
  ensure
    REDIS.del(breadcrumb_key(from_dev)) if from_dev
  end

  test "aborts the merge and keeps the visitor when the breadcrumb cannot be written" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair
    Event.create!(device: from_dev, project: @project, event: "view", platform: "ios")

    fold_ran = false
    assert_raises Redis::BaseError do
      @job.stub(:fold_visitor_into_survivor_in_clickhouse, ->(*) { fold_ran = true }) do
        @job.stub(:write_merge_breadcrumb, ->(*) { raise Redis::BaseError, "breadcrumb down" }) do
          perform_merge(from_dev, to_dev, from_vis)
        end
      end
    end

    assert Visitor.exists?(id: from_vis.id), "visitor delete must roll back with the breadcrumb"
    assert_equal 1, Event.where(device_id: from_dev.id).count, "events must stay on the source device"
    assert_not fold_ran, "no fold for an aborted merge"
  end

  test "writes the device-merge breadcrumb even when from_visitor is already gone" do
    from_dev = create_device("NoVisitor")
    to_dev = create_device("Target")
    Visitor.create!(device: to_dev, project: @project)

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_equal to_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev)),
      "queued events for the old device must still remap after a retried merge"
  ensure
    REDIS.del(breadcrumb_key(from_dev)) if from_dev
  end

  # --- Orchestration: device locks + Sidekiq-native retry ---

  test "uses Sidekiq retries instead of hand-rolled attempt counting" do
    assert_equal 10, MergeVisitorEventsJob.sidekiq_options["retry"],
      "merge durability relies on Sidekiq retry/backoff/dead-set"
  end

  test "requeues instead of merging when a device lock is held elsewhere" do
    require "sidekiq/testing"
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair
    # Simulate a sibling merge holding from_dev (e.g. X→from in flight)
    lock_key = "#{MergeVisitorEventsJob::LOCK_PREFIX}:#{from_dev.id}:#{@project.id}"
    REDIS.set(lock_key, "other-merge", ex: 60)

    Sidekiq::Testing.fake! do
      MergeVisitorEventsJob.clear
      @job.perform(from_dev.id, to_dev.id, @project.id)

      assert Visitor.exists?(id: from_vis.id), "must not merge while a device lock is held elsewhere"
      assert_equal 1, MergeVisitorEventsJob.jobs.size, "must requeue itself for retry"
    end
  ensure
    REDIS.del(lock_key) if lock_key
  end

  test "redirects the merge to the final device when the target was already merged away" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair
    final_dev = create_device("Final")
    Visitor.create!(device: final_dev, project: @project)
    # to_dev was already merged into final_dev
    to_vis = Visitor.find_by(device: to_dev, project: @project)
    to_vis.notification_messages.delete_all
    to_vis.delete
    REDIS.set(breadcrumb_key(to_dev), final_dev.id, ex: 86_400)

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_nil Visitor.find_by(device: to_dev, project: @project), "must not revive the merged-away target"
    assert_nil Visitor.find_by(id: from_vis.id), "source must be merged"
    assert_equal final_dev.id.to_s, REDIS.get(breadcrumb_key(to_dev)), "target's own breadcrumb must survive"
    assert_equal final_dev.id.to_s, REDIS.get(breadcrumb_key(from_dev)), "source must breadcrumb to the FINAL device"
  end

  test "self-merge is a no-op and does not requeue" do
    require "sidekiq/testing"
    dev = create_device("SelfMerge")
    Visitor.create!(device: dev, project: @project)

    Sidekiq::Testing.fake! do
      MergeVisitorEventsJob.clear
      @job.perform(dev.id, dev.id, @project.id)
      assert_equal 0, MergeVisitorEventsJob.jobs.size, "must not requeue itself forever"
    end
    assert Visitor.exists?(device: dev, project: @project)
  end

  test "releases both device locks after a successful merge" do
    from_dev, to_dev, from_vis, _to_vis = create_merge_pair

    perform_merge(from_dev, to_dev, from_vis)

    assert_nil Visitor.find_by(id: from_vis.id), "merge must have run"
    [from_dev, to_dev].each do |dev|
      assert_nil REDIS.get("#{MergeVisitorEventsJob::LOCK_PREFIX}:#{dev.id}:#{@project.id}"),
        "device lock for #{dev.id} must be released"
    end
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
  test "unprocessed purchases on the retired device repoint to the surviving device" do
    from_dev, to_dev, _from_vis, _to_vis = create_merge_pair
    pending = PurchaseEvent.create!(
      project: @project, device: from_dev, processed: false,
      event_type: Grovs::Purchases::EVENT_BUY, transaction_id: "txn_merge_pending", usd_price_cents: 100
    )

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_equal to_dev.id, pending.reload.device_id, "later processing must resolve the surviving visitor"
  end

  test "purchase ledger visitor_id follows the survivor" do
    from_dev, to_dev, from_vis, to_vis = create_merge_pair
    pe = PurchaseEvent.create!(
      project: @project, device: from_dev, visitor_id: from_vis.id, processed: true,
      event_type: Grovs::Purchases::EVENT_BUY, transaction_id: "txn_merge_ledger", usd_price_cents: 100
    )

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_equal to_vis.id, pe.reload.visitor_id
  end

  test "subscription state on the retired device follows the survivor" do
    from_dev, to_dev, = create_merge_pair
    state = SubscriptionState.create!(
      project: @project, device: from_dev, original_transaction_id: "otid_merge_#{SecureRandom.hex(4)}",
      product_id: "com.test.sub"
    )

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_equal to_dev.id, state.reload.device_id,
      "post-merge renewals read the survivor, not the retired device"
  end

  test "device product purchases follow the survivor, collapsing collisions" do
    from_dev, to_dev, = create_merge_pair
    moved = DeviceProductPurchase.create!(project: @project, device: from_dev, product_id: "com.only.from")
    DeviceProductPurchase.create!(project: @project, device: from_dev, product_id: "com.shared")
    DeviceProductPurchase.create!(project: @project, device: to_dev, product_id: "com.shared")

    @job.perform(from_dev.id, to_dev.id, @project.id)

    assert_equal to_dev.id, moved.reload.device_id
    assert_equal 1, DeviceProductPurchase.where(device_id: to_dev.id, project_id: @project.id, product_id: "com.shared").count,
      "the colliding from-row must be dropped, not violate the unique index"
    assert_equal 0, DeviceProductPurchase.where(device_id: from_dev.id).count
  end

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

  def create_device(label)
    Device.create!(
      user_agent: "#{label}/#{SecureRandom.hex(4)}",
      ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      platform: "ios"
    )
  end

  def breadcrumb_key(device)
    "#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:#{device.id}"
  end

  def perform_merge(from_dev, to_dev, _from_vis)
    @job.perform(from_dev.id, to_dev.id, @project.id)
  end
end
