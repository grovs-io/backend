require "test_helper"
require "sidekiq/testing"

class DeleteInstanceJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :visitors,
           :devices, :applications, :ios_configurations, :android_configurations,
           :desktop_configurations, :web_configurations, :custom_redirects,
           :stripe_subscriptions, :stripe_payment_intents,
           :visitor_daily_statistics

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    EnterpriseSubscription.delete_all
    CustomHostname.delete_all
  end

  test "waits for a slot while the deletion limit is reached, so the maintenance queue keeps threads for its ticks" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    far = (Time.now + 3600).to_f
    REDIS.with { |c| DeleteInstanceJob.slots.times { |i| c.zadd(DeleteInstanceJob::SLOT_KEY, far, "held-#{i}") } }
    Sidekiq::Testing.fake! do
      DeleteInstanceJob.clear
      DeleteInstanceJob.new.perform(@instance.id)
      assert Instance.exists?(@instance.id), "deleted while every slot was taken"
      assert_equal [[@instance.id]], DeleteInstanceJob.jobs.map { |j| j["args"] }
      assert_in_delta Time.now.to_f + DeleteInstanceJob::RETRY_IN, DeleteInstanceJob.jobs.first["at"], 5
    end
  ensure
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "an expired lease frees its slot, and a finished deletion releases its own" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    past = (Time.now - 1).to_f
    REDIS.with { |c| DeleteInstanceJob.slots.times { |i| c.zadd(DeleteInstanceJob::SLOT_KEY, past, "dead-#{i}") } }
    DeleteInstanceJob.new.perform(@instance.id)
    assert_nil Instance.find_by(id: @instance.id)
    assert_equal 0, REDIS.with { |c| c.zcard(DeleteInstanceJob::SLOT_KEY) }
  ensure
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "a batch that outruns the lease is followed by a renewal of the slot and the key" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    stalled = false
    stall = lambda do |*, payload|
      next if stalled || !payload[:sql].match?(/\ADELETE FROM "links"/)

      stalled = true
      travel(DeleteInstanceJob::LEASE + 1.hour)
      REDIS.with { |c| c.expire(DeleteInstanceJob::SLOT_KEY, 5) }
    end
    held = ttl = nil
    snapshot = lambda do |**|
      REDIS.with do |c|
        held = c.zrangebyscore(DeleteInstanceJob::SLOT_KEY, Time.now.to_f, "+inf").size
        ttl = c.ttl(DeleteInstanceJob::SLOT_KEY)
      end
    end
    ActiveSupport::Notifications.subscribed(stall, "sql.active_record") do
      Audit.stub(:record, snapshot) { DeleteInstanceJob.new.perform(@instance.id) }
    end
    assert stalled, "no link batch ran, so nothing was tested"
    assert_equal 1, held, "the slot lapsed while the deletion was still running"
    assert_operator ttl, :>, DeleteInstanceJob::LEASE - 60, "the key would expire under the running deletion"
  ensure
    travel_back
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "while one deletion runs a statement as long as the cap allows, no other can take its slot" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    previous = ENV.fetch("DELETE_INSTANCE_CONCURRENCY", nil)
    ENV["DELETE_INSTANCE_CONCURRENCY"] = "1"
    competitor = nil
    compete = lambda do |*, payload|
      next if !competitor.nil? || !payload[:sql].match?(/\ADELETE FROM "links"/)

      travel(DeleteInstanceJob::STATEMENT_TIMEOUT + 1.minute)
      competitor = DeleteInstanceJob.acquire_slot("competitor")
    end
    ActiveSupport::Notifications.subscribed(compete, "sql.active_record") { DeleteInstanceJob.new.perform(@instance.id) }
    assert_equal false, competitor, "a second deletion took the running one's slot"
    assert_nil Instance.find_by(id: @instance.id)
  ensure
    travel_back
    ENV["DELETE_INSTANCE_CONCURRENCY"] = previous
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "statements on other threads do not keep a deletion's slot alive" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    scores = []
    other_thread_sql = lambda do |_ids|
      travel(DeleteInstanceJob::LEASE + 1.hour)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { |conn| conn.select_value("SELECT 1") } }.join
      scores << REDIS.with { |c| c.zrangebyscore(DeleteInstanceJob::SLOT_KEY, Time.now.to_f, "+inf").size }
      true
    end
    ClickhouseDeleteService.stub(:delete_projects, other_thread_sql) { DeleteInstanceJob.new.perform(@instance.id) }
    assert_equal [0], scores
  ensure
    travel_back
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "the lease outlasts the longest statement the deletion lets run" do
    assert_operator DeleteInstanceJob::LEASE, :>, DeleteInstanceJob::STATEMENT_TIMEOUT
  end

  test "a concurrency of 0 still lets a deletion run instead of requeueing it for ever" do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    previous = ENV.fetch("DELETE_INSTANCE_CONCURRENCY", nil)
    ENV["DELETE_INSTANCE_CONCURRENCY"] = "0"
    DeleteInstanceJob.new.perform(@instance.id)
    assert_nil Instance.find_by(id: @instance.id)
  ensure
    ENV["DELETE_INSTANCE_CONCURRENCY"] = previous
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
  end

  test "deletes instance and all associated data" do
    # Instance one has a Stripe sub the job must clear (FK blocks destroy!).
    assert_operator StripeSubscription.where(instance_id: @instance.id).count, :>, 0

    job = DeleteInstanceJob.new

    job.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal 0, Project.where(instance_id: @instance.id).count
    assert_equal 0, Domain.where(project_id: @project.id).count
    assert_equal 0, Visitor.where(project_id: @project.id).count
    assert_equal 0, VisitorDailyStatistic.where(project_id: @project.id).count
    assert_equal 0, StripeSubscription.where(instance_id: @instance.id).count
    assert_equal 0, StripePaymentIntent.where(instance_id: @instance.id).count
  end

  test "purges ClickHouse data for the instance's projects" do
    project_ids = Project.where(instance_id: @instance.id).pluck(:id)
    captured = nil
    ClickhouseDeleteService.stub(:delete_projects, ->(ids) { captured = ids }) do
      DeleteInstanceJob.new.perform(@instance.id)
    end
    assert_equal project_ids.sort, Array(captured).sort
  end

  test "a failed ClickHouse sweep raises before the projects and instance are deleted" do
    ClickhouseDeleteService.stub(:delete_projects, ->(_ids) { false }) do
      assert_raises(RuntimeError) { DeleteInstanceJob.new.perform(@instance.id) }
    end
    assert Instance.exists?(@instance.id), "instance must survive so the retry can redo the sweep"
    assert Project.exists?(@project.id)
  end

  test "nonexistent instance returns early without deleting anything" do
    job = DeleteInstanceJob.new
    original_count = Instance.count

    job.perform(-999)

    assert_equal original_count, Instance.count
  end

  test "deletes the rows the instance left in the legacy notification tables, and no other instance's" do
    conn = ActiveRecord::Base.connection
    add = lambda do |project|
      id = conn.select_value("INSERT INTO notifications (project_id, title, created_at, updated_at) " \
                             "VALUES (#{project.id}, 'Old', now(), now()) RETURNING id")
      conn.execute("INSERT INTO notification_targets (notification_id, created_at, updated_at) VALUES (#{id}, now(), now())")
      conn.execute("INSERT INTO notification_messages (notification_id, visitor_id, created_at, updated_at) " \
                   "VALUES (#{id}, #{visitors(:ios_visitor).id}, now(), now())")
    end
    add.call(@project)
    other = Project.where.not(instance_id: @instance.id).first
    add.call(other)

    DeleteInstanceJob.new.perform(@instance.id)

    counts = %w[notifications notification_targets notification_messages].map { |t| conn.select_value("SELECT count(*) FROM #{t}").to_i }
    assert_equal [1, 1, 1], counts
    assert_equal other.id, conn.select_value("SELECT project_id FROM notifications").to_i
  end

  test "deletes custom hostnames through Cloudflare before bulk-deleting projects" do
    enable_custom_domains!
    CustomHostname.delete_all
    custom_hostname = CustomHostname.create!(
      project: @project,
      domain: domains(:one),
      hostname: "links.instance-delete.com",
      cf_custom_hostname_id: "cf_instance_delete",
      status: "active",
      source: "saas"
    )
    domains(:one).update!(active_custom_host: custom_hostname.hostname)

    deleted_cf_ids = []
    CloudflareCustomHostnameService.stub(:delete, lambda { |cf_id:| 
      deleted_cf_ids << cf_id
      true
    }) do
      DeleteInstanceJob.new.perform(@instance.id)
    end

    assert_includes deleted_cf_ids, "cf_instance_delete"
    assert_not CustomHostname.exists?(custom_hostname.id)
  ensure
    disable_custom_domains!
  end

  test "keeps tenant rows and suspends custom hostname when Cloudflare deletion fails" do
    enable_custom_domains!
    CustomHostname.delete_all
    custom_hostname = CustomHostname.create!(
      project: @project,
      domain: domains(:one),
      hostname: "links.instance-delete-fail.com",
      cf_custom_hostname_id: "cf_instance_delete_fail",
      status: "active",
      source: "saas"
    )
    domains(:one).update!(active_custom_host: custom_hostname.hostname)

    CloudflareCustomHostnameService.stub(:delete, false) do
      assert_raises(RuntimeError) { DeleteInstanceJob.new.perform(@instance.id) }
    end

    assert Instance.exists?(@instance.id), "tenant deletion must retry instead of orphaning records"
    assert Project.exists?(@project.id)
    assert Domain.exists?(domains(:one).id)
    custom_hostname.reload
    assert_equal "suspended", custom_hostname.status
    assert_not custom_hostname.resolvable?
    assert_nil domains(:one).reload.active_custom_host
  ensure
    CustomHostname.where(id: custom_hostname&.id).delete_all
    disable_custom_domains!
  end

  test "deletes visitor daily statistics for target projects only" do
    project_ids = Project.where(instance_id: @instance.id).pluck(:id)
    assert VisitorDailyStatistic.where(project_id: project_ids).exists?,
      "Fixture should have visitor daily statistics for instance projects"

    # Create a stat for the other instance to verify it survives
    other_project = projects(:two)
    other_device = Device.create!(vendor: "other-vendor-001", platform: "ios",
      user_agent: "TestApp/1.0", ip: "192.168.1.99", remote_ip: "10.0.0.99")
    other_visitor = Visitor.create!(project: other_project, device: other_device, web_visitor: false)
    other_stat = VisitorDailyStatistic.create!(
      visitor: other_visitor, project_id: other_project.id,
      event_date: "2026-03-01", platform: "ios"
    )

    job = DeleteInstanceJob.new
    job.perform(@instance.id)

    assert_equal 0, VisitorDailyStatistic.where(project_id: project_ids).count,
      "All visitor daily statistics for deleted instance should be removed"
    assert VisitorDailyStatistic.exists?(other_stat.id),
      "Visitor daily statistics for other instances should be untouched"
  end

  test "deletes screen aliases so the projects FK does not block deletion" do
    ScreenAlias.create!(project: @project, screen_identifier: "home", alias_name: "Home")
    other_alias = ScreenAlias.create!(project: projects(:two), screen_identifier: "home", alias_name: "Home")

    DeleteInstanceJob.new.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal 0, ScreenAlias.where(project_id: @project.id).count
    assert ScreenAlias.exists?(other_alias.id)
  end

  test "deletes dashboards and their widgets so the projects FK does not block deletion" do
    dashboard = Dashboard.create!(project: @project, name: "Growth")
    widget = dashboard.widgets.create!(title: "Installs", query: { metric: "installs" })
    other = Dashboard.create!(project: projects(:two), name: "Other")

    DeleteInstanceJob.new.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_not Dashboard.exists?(dashboard.id)
    assert_not DashboardWidget.exists?(widget.id)
    assert Dashboard.exists?(other.id)
  end

  test "removes push campaigns, their deliveries and their images with the tenant" do
    skip "enterprise tree absent" unless defined?(PushCampaign)

    campaign = PushCampaign.create!(project: @project, name: "c", title: "t", body: "b", audience_type: "visitors",
                                    recipients: [visitors(:ios_visitor).uuid])
    campaign.image.attach(io: File.open(Rails.root.join("test/fixtures/files/push.png")), filename: "push.png", content_type: "image/png")
    campaign.save!
    blob_id = campaign.image.blob.id
    app = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    queued = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x")
    PushDelivery.create!(push_campaign: campaign, visitor: visitors(:ios_visitor), device_id: visitors(:ios_visitor).device_id,
                         platform: "ios", status: "queued", rpush_notification_id: queued.id)

    DeleteInstanceJob.new.perform(@instance.id)

    assert_nil PushCampaign.find_by(id: campaign.id)
    assert_equal 0, PushDelivery.where(push_campaign_id: campaign.id).count
    assert_nil ActiveStorage::Blob.find_by(id: blob_id)
    assert_nil Rpush::Notification.find_by(id: queued.id), "a queued push must not go out after the tenant is gone"
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "removes the tenant's rpush apps and their pushes, and nobody else's" do
    ios_push = IosPushConfiguration.new(name: "ios_config_tenant", certificate_password: "K", ios_configuration: ios_configurations(:one))
    ios_push.certificate.attach(ActiveStorage::Blob.create_and_upload!(io: StringIO.new(OpenSSL::PKey::EC.generate("prime256v1").private_to_pem),
                                                                     filename: "k.p8"))
    ios_push.save!
    other = Rpush::Apnsp8::App.create!(name: "ios_config_other-production", environment: "production", apn_key: "k", apn_key_id: "id",
                                       team_id: "t", bundle_id: "b", connections: 1)
    tenant_app = Rpush::Apnsp8::App.find_by!(name: "ios_config_tenant-production")
    unsent = Rpush::Apnsp8::Notification.create!(app: tenant_app, device_token: "a" * 64, alert: "x")

    DeleteInstanceJob.new.perform(@instance.id)

    assert_empty Rpush::Client::ActiveRecord::App.where("name LIKE ?", "ios_config_tenant-%")
    assert_not Rpush::Client::ActiveRecord::Notification.exists?(unsent.id)
    assert Rpush::Client::ActiveRecord::App.exists?(other.id)
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "cascades segment size snapshots via the FK when segments are removed" do
    skip "enterprise tree absent" unless defined?(Segment)

    definition = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
    ] }] }
    segment = Segment.create!(project: @project, name: "S", definition: definition)
    SegmentSizeSnapshot.create!(segment: segment, date: Date.current, definition_hash: segment.definition_hash, persons: 1, devices: 1)

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, SegmentSizeSnapshot.where(segment_id: segment.id).count
  end

  test "with_local_timeouts rejects invalid format" do
    job = DeleteInstanceJob.new

    assert_raises(ArgumentError) do
      job.send(:with_local_timeouts, lock: "'; DROP TABLE users;--") {}
    end

    assert_raises(ArgumentError) do
      job.send(:with_local_timeouts, lock: "2s", statement: "abc") {}
    end
  end
end
