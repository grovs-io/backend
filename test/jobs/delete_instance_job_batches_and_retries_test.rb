require "test_helper"

class DeleteInstanceJobBatchesAndRetriesTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :visitors, :devices, :applications,
           :ios_configurations, :android_configurations, :desktop_configurations, :web_configurations,
           :custom_redirects, :stripe_subscriptions, :stripe_payment_intents

  setup do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    CustomHostname.delete_all
    @instance = instances(:one)
    @tenant_ids = [projects(:one).id, projects(:one_test).id]
    @bystander = projects(:two)
  end

  teardown { REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) } }

  def with_batch_sizes(batch:, sub_batch: DeleteInstanceJob::SUB_BATCH_SIZE)
    saved = { BATCH_SIZE: DeleteInstanceJob::BATCH_SIZE, SUB_BATCH_SIZE: DeleteInstanceJob::SUB_BATCH_SIZE }
    silence_warnings do
      DeleteInstanceJob.const_set(:BATCH_SIZE, batch)
      DeleteInstanceJob.const_set(:SUB_BATCH_SIZE, sub_batch)
    end
    yield
  ensure
    silence_warnings { saved.each { |name, value| DeleteInstanceJob.const_set(name, value) } }
  end

  def statements_matching(pattern, &)
    seen = []
    collect = ->(*, payload) { seen << payload[:sql] if payload[:sql].match?(pattern) }
    ActiveSupport::Notifications.subscribed(collect, "sql.active_record", &)
    seen
  end

  def link_stat(project_id, link, days_ago = 0)
    { project_id: project_id, link_id: link.id, event_date: Date.current - days_ago, platform: "web" }
  end

  test "a primary-key-less table larger than one batch is emptied chunk by chunk, and only for the tenant" do
    LinkDailyStatistic.insert_all!(Array.new(5) { |i| link_stat(@tenant_ids[i % 2], links(:basic_link), i) })
    LinkDailyStatistic.insert_all!(Array.new(2) { |i| link_stat(@bystander.id, links(:second_link), i) })

    chunks = with_batch_sizes(batch: 2) do
      statements_matching(/DELETE FROM link_daily_statistics t/) { DeleteInstanceJob.new.perform(@instance.id) }
    end

    assert_operator chunks.size, :>=, 3, "5 rows in chunks of 2 need at least three passes"
    assert_equal 0, LinkDailyStatistic.where(project_id: @tenant_ids).count
    assert_equal 2, LinkDailyStatistic.where(project_id: @bystander.id).count
  end

  test "a keyed table larger than one batch is emptied across batches, and only for the tenant" do
    devices = Array.new(5) { |i| Device.create!(vendor: "dij-b#{i}", platform: "ios", user_agent: "T/1", ip: "10.2.0.#{i}", remote_ip: "10.2.0.#{i}") }
    DeviceLastSeen.insert_all!(devices.each_with_index.map { |d, i| { project_id: @tenant_ids[i % 2], device_id: d.id, last_seen_at: Time.current } })
    DeviceLastSeen.insert_all!(devices.first(3).map { |d| { project_id: @bystander.id, device_id: d.id, last_seen_at: Time.current } })

    with_batch_sizes(batch: 2) { DeleteInstanceJob.new.perform(@instance.id) }

    assert_equal 0, DeviceLastSeen.where(project_id: @tenant_ids).count
    assert_equal 3, DeviceLastSeen.where(project_id: @bystander.id).count
  end

  test "links spread over several batches and slices lose every action and custom redirect, and nobody else's" do
    domain = domains(:one)
    ids = Link.insert_all!(Array.new(5) do |i|
      { domain_id: domain.id, redirect_config_id: redirect_configs(:one).id, path: "dij-batch-#{i}", generated_from_platform: "web" }
    end, returning: :id).rows.flatten
    other = links(:second_link)
    before = [Action.where(link_id: other.id).count, CustomRedirect.where(link_id: other.id).count]
    Action.insert_all!((ids + [other.id]).map { |id| { link_id: id, device_id: devices(:ios_device).id } })
    CustomRedirect.insert_all!((ids + [other.id]).map { |id| { link_id: id, platform: "ios", url: "https://x.example.com/#{id}" } })

    with_batch_sizes(batch: 2, sub_batch: 1) { DeleteInstanceJob.new.perform(@instance.id) }

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal [0, 0, 0], [Link.where(id: ids).count, Action.where(link_id: ids).count, CustomRedirect.where(link_id: ids).count]
    assert_equal before.map(&:succ), [Action.where(link_id: other.id).count, CustomRedirect.where(link_id: other.id).count]
    assert Link.exists?(other.id)
  end

  test "legacy notification messages beyond one page are all removed, and another tenant's stay" do
    conn = ActiveRecord::Base.connection
    add = lambda do |project_id, messages|
      id = conn.select_value("INSERT INTO notifications (project_id, title, created_at, updated_at) VALUES (#{project_id}, 'Old', now(), now()) RETURNING id")
      messages.times do
        conn.execute("INSERT INTO notification_messages (notification_id, visitor_id, created_at, updated_at) " \
                     "VALUES (#{id}, #{visitors(:ios_visitor).id}, now(), now())")
      end
      id
    end
    add.call(@tenant_ids.first, 5)
    other = add.call(@bystander.id, 2)

    pages = with_batch_sizes(batch: 2) do
      statements_matching(/\ADELETE FROM notification_messages/) { DeleteInstanceJob.new.perform(@instance.id) }
    end

    assert_operator pages.size, :>=, 3
    assert_equal 2, conn.select_value("SELECT count(*) FROM notification_messages").to_i
    assert_equal 2, conn.select_value("SELECT count(*) FROM notification_messages WHERE notification_id = #{other}").to_i
  end

  test "a step failing midway keeps the tenant and frees the slot, and the retry finishes the teardown" do
    DeviceLastSeen.insert_all!([{ project_id: @tenant_ids.first, device_id: devices(:web_device).id, last_seen_at: Time.current },
                                { project_id: @bystander.id, device_id: devices(:web_device).id, last_seen_at: Time.current }])
    tenant_domain = domains(:one).id
    first = DeleteInstanceJob.new
    first.stub(:remove_applications_for_instance, ->(_id) { raise "lock timeout" }) do
      assert_raises(RuntimeError) { first.perform(@instance.id) }
    end

    assert Instance.exists?(@instance.id)
    assert_equal 2, Project.where(id: @tenant_ids).count
    assert_equal 0, Link.where(domain_id: tenant_domain).count, "the steps before the failure did run"
    assert_equal 0, REDIS.with { |c| c.zcard(DeleteInstanceJob::SLOT_KEY) }, "a failed run must not hold its slot until the lease lapses"

    DeleteInstanceJob.new.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal 0, Application.where(instance_id: @instance.id).count
    assert_equal 0, DeviceLastSeen.where(project_id: @tenant_ids).count
    assert_equal 1, DeviceLastSeen.where(project_id: @bystander.id, device_id: devices(:web_device).id).count
    assert Link.exists?(links(:second_link).id)
  end

  test "a retry that finds the projects already gone deletes the instance and no other tenant's rows" do
    DeviceLastSeen.insert_all!([{ project_id: @bystander.id, device_id: devices(:web_device).id, last_seen_at: Time.current }])
    LinkDailyStatistic.insert_all!([link_stat(@bystander.id, links(:second_link))])
    DailyProjectMetric.insert_all!([{ project_id: @bystander.id, event_date: Date.current }])
    ProjectDailyActiveUser.insert_all!([{ project_id: @bystander.id, event_date: Date.current }])
    Audit.stub(:record, ->(**) { raise "audit store down" }) do
      assert_raises(RuntimeError) { DeleteInstanceJob.new.perform(@instance.id) }
    end
    assert Instance.exists?(@instance.id), "the failed audit must roll the instance delete back"
    assert_equal 0, Project.where(instance_id: @instance.id).count
    bystander = -> { [DeviceLastSeen, LinkDailyStatistic, DailyProjectMetric, ProjectDailyActiveUser, Visitor, Domain, Link].map { |m| m.unscoped.count } }
    before = bystander.call

    DeleteInstanceJob.new.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal before, bystander.call
    assert_equal 1, Project.where(id: @bystander.id).count
  end

  test "a retry after a failed audit still records the deletion for an entitled instance" do
    EnterpriseSubscription.create!(instance: @instance, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 10)
    Audit.stub(:record, ->(**) { raise "audit store down" }) do
      assert_raises(RuntimeError) { DeleteInstanceJob.new.perform(@instance.id) }
    end
    recorded = []
    Audit.stub(:record, ->(**args) { recorded << args }) { DeleteInstanceJob.new.perform(@instance.id) }

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal [["instance.deleted", true]], recorded.map { |a| [a[:action], a[:entitled]] }
  end
end
