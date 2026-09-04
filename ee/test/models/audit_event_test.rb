require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    @user = users(:admin_user)
    entitle!(@instance)
    Current.reset
  end

  teardown { Current.reset }

  test "record writes a row with sequence 1 and a hash, no prev_hash" do
    ev = AuditEvent.record(instance_id: @instance.id, action: "instance.renamed",
                           actor: AuditActor.user(@user, via: "password"),
                           target: { "type" => "instance", "id" => @instance.id },
                           changes: { "before" => { "name" => "a" }, "after" => { "name" => "b" } })
    assert_equal 1, ev.sequence
    assert_nil ev.prev_hash
    assert_match(/\A[0-9a-f]{64}\z/, ev.hash_value)
    assert_equal "user", ev.actor["type"]
    assert_equal @user.email, ev.actor["email"]
  end

  test "second record chains to the first" do
    first = AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    second = AuditEvent.record(instance_id: @instance.id, action: "link.updated", actor: AuditActor.system("test"))
    assert_equal 2, second.sequence
    assert_equal first.hash_value, second.prev_hash
    assert_equal({ ok: true, count: 2 }, AuditEvent.verify_chain(@instance.id))
  end

  test "hash survives a reload, including Time and Date values in changes" do
    ev = AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"),
                           changes: { "after" => { "z" => 1, "a" => 2, "end_date" => Time.utc(2026, 8, 28, 10, 0, 0, 123456), "d" => Date.new(2026, 1, 2) } })
    reloaded = AuditEvent.find(ev.id)
    assert_equal ev.hash_value, reloaded.compute_hash
    assert_equal({ ok: true, count: 1 }, AuditEvent.verify_chain(@instance.id))
  end

  test "target_for names the record type and id" do
    assert_equal({ "type" => "instance", "id" => @instance.id }, Audit.target_for(@instance))
  end

  test "tampering is detected by verify_chain" do
    AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    AuditEvent.record(instance_id: @instance.id, action: "link.updated", actor: AuditActor.system("test"))
    AuditEvent.connection.execute("UPDATE audit_events SET action = 'link.deleted' WHERE instance_id = #{@instance.id} AND sequence = 1")
    result = AuditEvent.verify_chain(@instance.id)
    assert_equal false, result[:ok]
    assert_equal 1, result[:sequence]
  end

  test "deleting trailing rows is detected as truncation" do
    AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    AuditEvent.record(instance_id: @instance.id, action: "link.updated", actor: AuditActor.system("test"))
    AuditEvent.connection.execute("DELETE FROM audit_events WHERE instance_id = #{@instance.id} AND sequence = 2")
    result = AuditEvent.verify_chain(@instance.id)
    assert_equal false, result[:ok]
    assert_match(/truncated/, result[:reason])
  end

  test "deleting the chain head row is detected" do
    AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    AuditChainHead.where(instance_id: @instance.id).delete_all
    result = AuditEvent.verify_chain(@instance.id)
    assert_equal false, result[:ok]
    assert_match(/head missing/, result[:reason])
  end

  test "a lapsed subscription row beside the active one does not disable auditing" do
    unentitle!(@instance)
    EnterpriseSubscription.create!(instance: @instance, active: false, start_date: 2.years.ago,
                                   end_date: 1.year.ago, total_maus: 100)
    entitle!(@instance)
    fresh = Instance.find(@instance.id)
    assert fresh.audit_log_enabled?
    assert fresh.valid_enterprise_subscription.active
  end

  test "entitled: true records for an unentitled instance, entitled: false suppresses an entitled one" do
    other = instances(:two)
    assert_not_nil AuditEvent.record(instance_id: other.id, action: "enterprise_subscription.updated", actor: AuditActor.admin_key, entitled: true)
    assert_nil AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"), entitled: false)
  end

  test "secrets are redacted in changes" do
    ev = AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"),
                           changes: { "after" => { "api_key" => "shh", "push_certificate_password" => "x", "name" => "ok" } })
    assert_equal "[FILTERED]", ev.changes_data["after"]["api_key"]
    assert_equal "[FILTERED]", ev.changes_data["after"]["push_certificate_password"]
    assert_equal "ok", ev.changes_data["after"]["name"]
  end

  test "record is a no-op for an unentitled instance" do
    other = instances(:two)
    assert_nil AuditEvent.record(instance_id: other.id, action: "link.created", actor: AuditActor.system("test"))
    assert_equal 0, AuditEvent.where(instance_id: other.id).count
  end

  test "record is on for every instance when self-hosted" do
    other = instances(:two)
    Grovs.stub(:self_hosted?, true) do
      assert_not_nil AuditEvent.record(instance_id: other.id, action: "link.created", actor: AuditActor.system("test"))
    end
  end

  test "record picks up ip/ua/request_id from Current" do
    Current.ip = "203.0.113.9"
    Current.user_agent = "UA"
    Current.request_id = "req-1"
    ev = AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    assert_equal "203.0.113.9", ev.ip
    assert_equal "req-1", ev.request_id
  end

  test "record_for_user fans out to entitled instances only" do
    rows = AuditEvent.record_for_user(user: @user, action: "user.login", actor: AuditActor.user(@user, via: "password"))
    assert_equal [@instance.id], rows.map(&:instance_id)
  end

  test "diff builds before/after from saved_changes" do
    @instance.update!(uri_scheme: "newscheme")
    d = Audit.diff(@instance)
    assert_equal "testapp", d["before"]["uri_scheme"]
    assert_equal "newscheme", d["after"]["uri_scheme"]
    assert_not d["before"].key?("updated_at")
  end

  test "an unknown action name is rejected" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AuditEvent.record(instance_id: @instance.id, action: "link.typo", actor: AuditActor.system("test"))
    end
  end

  test "rows cannot be updated or deleted through the model" do
    ev = AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("test"))
    assert_raises(ActiveRecord::ReadOnlyRecord) { ev.update!(action: "link.deleted") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { ev.destroy! }
  end
end
