require "test_helper"

class DeleteInstanceJobTenantIsolationTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :visitors, :devices, :applications,
           :ios_configurations, :android_configurations, :desktop_configurations, :web_configurations,
           :custom_redirects, :stripe_subscriptions, :stripe_payment_intents, :campaigns

  setup do
    REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) }
    CustomHostname.delete_all
    @instance = instances(:one)
    @tenant = [projects(:one), projects(:one_test)]
    @bystander = projects(:two)
    @visitors = {
      projects(:one).id => visitors(:ios_visitor),
      projects(:one_test).id => Visitor.create!(project: projects(:one_test), device: devices(:android_device), web_visitor: false),
      @bystander.id => Visitor.create!(project: @bystander, device: devices(:ios_device), web_visitor: false)
    }
    @device = Device.create!(vendor: "dij-iso", platform: "ios", user_agent: "T/1", ip: "10.1.1.1", remote_ip: "10.1.1.1")
    @links = { projects(:one).id => links(:basic_link), projects(:one_test).id => links(:basic_link), @bystander.id => links(:second_link) }
  end

  teardown { REDIS.with { |c| c.del(DeleteInstanceJob::SLOT_KEY) } }

  PROJECT_SCOPED = {
    "iap webhook messages" => ["IapWebhookMessage", ->(p) { { project_id: p.id, payload: "{}", source: "apple" } }],
    "installed apps" => ["InstalledApp", ->(p) { { project_id: p.id, device_id: @device.id } }],
    "purchase events" => ["PurchaseEvent", ->(p) { { project_id: p.id, event_type: "buy", visitor_id: @visitors[p.id].id } }],
    "visitor last visits" => ["VisitorLastVisit", ->(p) { { project_id: p.id, visitor_id: @visitors[p.id].id, link_id: @links[p.id].id } }],
    "device last seens" => ["DeviceLastSeen", ->(p) { { project_id: p.id, device_id: @device.id, last_seen_at: Time.current } }],
    "campaigns" => ["Campaign", ->(p) { { project_id: p.id, name: "c#{p.id}" } }],
    "project daily active users" => ["ProjectDailyActiveUser", ->(p) { { project_id: p.id, event_date: Date.current, active_users: 3 } }],
    "link daily statistics" => ["LinkDailyStatistic", ->(p) { { project_id: p.id, link_id: @links[p.id].id, event_date: Date.current } }],
    "daily project metrics" => ["DailyProjectMetric", ->(p) { { project_id: p.id, event_date: Date.current } }],
    "event destinations" => ["EventDestination", ->(p) { { project_id: p.id, name: "d", kind: "webhook" } }],
    "event stream tokens" => ["EventStreamToken", ->(p) { { project_id: p.id, name: "t", token_digest: "digest-#{p.id}" } }],
    "segment memberships" => ["SegmentMembership", ->(p) { { project_id: p.id, visitor_id: @visitors[p.id].id, segment_key: "k", confirmed_at: Time.now } }],
    "in-app settings" => ["InAppSetting", ->(p) { { project_id: p.id } }],
    "journeys" => ["Journey", ->(p) { { project_id: p.id, name: "j" } }],
    "push campaigns" => ["PushCampaign", ->(p) { { project_id: p.id, name: "n", title: "t", body: "b", audience_type: "visitors" } }]
  }.freeze

  PROJECT_SCOPED.each do |label, (model_name, attrs)|
    test "removes the tenant's #{label} across both of its projects and leaves another instance's alone" do
      skip "enterprise tree absent" unless Object.const_defined?(model_name)

      model = model_name.constantize
      before = model.unscoped.where(project_id: @bystander.id).count
      model.insert_all!((@tenant + [@bystander]).map { |p| instance_exec(p, &attrs) })
      assert_operator model.unscoped.where(project_id: @tenant.map(&:id)).count, :>=, 2

      DeleteInstanceJob.new.perform(@instance.id)

      assert_nil Instance.find_by(id: @instance.id)
      assert_equal 0, model.unscoped.where(project_id: @tenant.map(&:id)).count
      assert_equal before + 1, model.unscoped.where(project_id: @bystander.id).count
    end
  end

  test "removes the tenant's links with their actions and custom redirects, and keeps the other instance's" do
    tenant_link = links(:basic_link)
    other_link = links(:second_link)
    Action.insert_all!([tenant_link, other_link].map { |l| { link_id: l.id, device_id: @device.id } })
    CustomRedirect.create!(link: other_link, platform: "ios", url: "https://other.example.com")
    tenant_domains = Domain.where(project_id: @tenant.map(&:id)).pluck(:id)
    assert_operator CustomRedirect.where(link_id: tenant_link.id).count, :>, 0

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, Link.where(domain_id: tenant_domains).count
    assert_equal 0, Domain.where(id: tenant_domains).count
    assert_equal [0, 0], [Action.where(link_id: tenant_link.id).count, CustomRedirect.where(link_id: tenant_link.id).count]
    assert Link.exists?(other_link.id)
    assert Domain.exists?(domains(:two).id)
    assert_equal [1, 1], [Action.where(link_id: other_link.id, device_id: @device.id).count, CustomRedirect.where(link_id: other_link.id).count]
  end

  test "removes the tenant's redirect configs and their redirects, and keeps the other instance's" do
    other_config = RedirectConfig.create!(project: @bystander)
    Redirect.create!(redirect_config: redirect_configs(:one), application: applications(:ios_app), platform: "ios", variation: "phone")
    other_redirect = Redirect.create!(redirect_config: other_config, application: applications(:second_ios_app), platform: "ios", variation: "phone")

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, RedirectConfig.where(project_id: @tenant.map(&:id)).count
    assert_equal 0, Redirect.where(redirect_config_id: redirect_configs(:one).id).count
    assert_equal [other_redirect.id], Redirect.where(redirect_config_id: other_config.id).pluck(:id)
  end

  test "removes every platform config of the tenant's applications and none of another instance's" do
    tenant_apps = Application.where(instance_id: @instance.id).pluck(:id)
    WebConfigurationLinkedDomain.create!(web_configuration: web_configurations(:one), domain: "a.example.com")
    other_ios = IosConfiguration.create!(application: applications(:second_ios_app), bundle_id: "com.other", app_prefix: "XYZ")
    configs = [IosConfiguration, AndroidConfiguration, DesktopConfiguration, WebConfiguration]

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, Application.where(id: tenant_apps).count
    assert_equal [0, 0, 0, 0], configs.map { |c| c.where(application_id: tenant_apps).count }
    assert_equal 0, WebConfigurationLinkedDomain.where(web_configuration_id: web_configurations(:one).id).count
    assert Application.exists?(applications(:second_ios_app).id)
    assert IosConfiguration.exists?(other_ios.id)
  end

  test "removes the tenant's smart banners and their link rows, and keeps the other instance's" do
    banner = SmartBanner.create!(project: projects(:one), name: "Mine", title: "Get it")
    SmartBannerLink.create!(smart_banner: banner, data_hash: "h1", link: links(:basic_link))
    other = SmartBanner.create!(project: @bystander, name: "Theirs", title: "Get it")
    other_link = SmartBannerLink.create!(smart_banner: other, data_hash: "h2", link: links(:second_link))

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, SmartBanner.where(project_id: @tenant.map(&:id)).count
    assert_equal 0, SmartBannerLink.where(smart_banner_id: banner.id).count
    assert_equal [other_link.id], SmartBannerLink.where(smart_banner_id: other.id).pluck(:id)
  end

  test "removes the instance's enterprise and Stripe subscriptions and only those" do
    EnterpriseSubscription.where(instance_id: [@instance.id, instances(:two).id]).delete_all
    [@instance, instances(:two)].each do |i|
      EnterpriseSubscription.create!(instance: i, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 10)
    end
    other_stripe = [StripeSubscription.where(instance_id: instances(:two).id).count, StripePaymentIntent.where(instance_id: instances(:two).id).count]
    assert_equal [1, 1], other_stripe

    DeleteInstanceJob.new.perform(@instance.id)

    assert_equal 0, EnterpriseSubscription.where(instance_id: @instance.id).count
    assert_equal 1, EnterpriseSubscription.where(instance_id: instances(:two).id).count
    assert_equal [0, 0], [StripeSubscription.where(instance_id: @instance.id).count, StripePaymentIntent.where(instance_id: @instance.id).count]
    assert_equal other_stripe, [StripeSubscription.where(instance_id: instances(:two).id).count,
                                StripePaymentIntent.where(instance_id: instances(:two).id).count]
  end

  test "removes the tenant's segments with their exports, in-app campaigns and views, and keeps the other instance's" do
    skip "enterprise tree absent" unless defined?(SegmentExport) && defined?(InAppView)

    definition = { "version" => 1, "operator" => "or", "groups" => [{ "operator" => "and", "conditions" => [
      { "type" => "event", "any" => true, "window" => { "last_days" => 30 } }
    ] }] }
    rows = (@tenant + [@bystander]).to_h do |p|
      segment = Segment.create!(project: p, name: "S", definition: definition)
      SegmentExport.insert_all!([{ project_id: p.id, segment_id: segment.id, definition_hash: segment.definition_hash }])
      campaign_id = InAppCampaign.insert_all!([{ project_id: p.id, name: "c" }], returning: :id).first["id"]
      InAppView.insert_all!([{ project_id: p.id, in_app_campaign_id: campaign_id, person_key: "v1" }])
      [p.id, segment.id]
    end
    tenant_ids = @tenant.map(&:id)

    DeleteInstanceJob.new.perform(@instance.id)

    tenant_counts = [Segment, SegmentExport, InAppCampaign, InAppView].map { |m| m.where(project_id: tenant_ids).count }
    assert_equal [0, 0, 0, 0], tenant_counts
    assert_equal [1, 1, 1, 1], [Segment, SegmentExport, InAppCampaign, InAppView].map { |m| m.where(project_id: @bystander.id).count }
    assert Segment.exists?(rows[@bystander.id])
  end

  test "stops the outbox capture and purges it for every tenant project and for no other project" do
    skip "enterprise tree absent" unless defined?(EventStream::Outbox)

    disabled = []
    purged = []
    EventStream::Outbox.stub(:disable_project!, ->(pid) { disabled << pid }) do
      EventStream::Outbox.stub(:purge_project!, ->(pid) { purged << pid }) do
        DeleteInstanceJob.new.perform(@instance.id)
      end
    end

    assert_equal @tenant.map(&:id).sort, disabled.sort
    assert_equal @tenant.map(&:id).sort, purged.sort
  end

  test "an outbox purge failing for one project still purges the next one and still deletes the tenant" do
    skip "enterprise tree absent" unless defined?(EventStream::Outbox)

    first, second = @tenant.map(&:id).sort
    purged = []
    purge = ->(pid) { pid == first ? raise("clickhouse down") : purged << pid }
    EventStream::Outbox.stub(:disable_project!, ->(_pid) {}) do
      EventStream::Outbox.stub(:purge_project!, purge) { DeleteInstanceJob.new.perform(@instance.id) }
    end

    assert_equal [second], purged
    assert_nil Instance.find_by(id: @instance.id)
  end
end
