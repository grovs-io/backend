require "test_helper"

class AuditSystemEventsTest < ActiveSupport::TestCase
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :domains, :stripe_subscriptions, :stripe_payment_intents, :custom_hostnames

  setup do
    @instance = instances(:one)
    entitle!(@instance)
    # DeleteInstanceJob calls Cloudflare for every custom hostname; none of these tests are about that.
    CustomHostname.where(project_id: Project.where(instance_id: @instance.id).select(:id)).delete_all
  end

  test "DeleteInstanceJob records instance.deleted after the teardown and the rows survive" do
    id = @instance.id
    DeleteInstanceJob.new.perform(id)
    assert_nil Instance.find_by(id: id)
    ev = AuditEvent.where(instance_id: id).order(:sequence).last
    assert_equal "instance.deleted", ev.action
    assert_equal "system", ev.actor["type"]
    assert_equal "DeleteInstanceJob", ev.actor["id"]
    assert_equal 1, AuditEvent.where(instance_id: id, action: "instance.deleted").count
  end

  test "DeleteInstanceJob writes nothing when the teardown raises" do
    CloudflareCustomHostnameService.stub(:delete, ->(*) { raise "cloudflare down" }) do
      CustomHostname.create!(project: @instance.production, domain: @instance.production.domain, hostname: "x.example.com",
                             status: "active", source: "saas", purpose: "primary", cf_custom_hostname_id: "cf1")
      assert_raises(RuntimeError) { DeleteInstanceJob.new.perform(@instance.id) }
    end
    assert_equal 0, AuditEvent.where(instance_id: @instance.id, action: "instance.deleted").count
  end

  test "quota transitions are audited" do
    keys = %w[FREE_MAU_COUNT FREE_PASS_PROJECT_IDS PUBLIC_GO_PROJECT_IDENTIFIER_ID]
    saved = keys.index_with { |k| ENV[k] }
    ENV["FREE_MAU_COUNT"] = "10"
    ENV["FREE_PASS_PROJECT_IDS"] = ""
    ENV["PUBLIC_GO_PROJECT_IDENTIFIER_ID"] = "0"
    @instance.update!(quota_exceeded: true)
    # Enterprise branch: quota_exceeded is forced false without a MAU read, so no ClickHouse/ProjectService stub is needed.
    Grovs.stub(:self_hosted?, false) { DisableQuotasJob.new.disable_quotas }
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "quota.restored").count
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "a stripe change in request context is attributed to the acting user, not the system" do
    Current.actor = AuditActor.user(users(:admin_user), via: "dashboard")
    stripe_subscriptions(:active_sub).update!(status: "canceled")
    ev = AuditEvent.where(instance_id: @instance.id, action: "subscription.changed").last
    assert_equal "user", ev.actor["type"]
    assert_equal users(:admin_user).email, ev.actor["email"]
  ensure
    Current.reset
  end

  test "stripe subscription state change is audited" do
    sub = stripe_subscriptions(:active_sub)
    sub.update!(status: "past_due")
    ev = AuditEvent.where(instance_id: @instance.id, action: "subscription.changed").last
    assert_equal "active", ev.changes_data["before"]["status"]
    assert_equal "past_due", ev.changes_data["after"]["status"]
  end
end
