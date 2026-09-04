require "test_helper"

class CustomHostnameActivationTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  setup do
    enable_manual_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
  end
  teardown { disable_custom_domains! }

  def manual_row(purpose: "primary", status: "pending")
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.selfhosted.com", cf_custom_hostname_id: nil,
                           status: status, source: "enterprise", purpose: purpose)
  end

  test "activates a pending row and stamps activated_at" do
    ch = manual_row
    assert CustomHostnameActivation.apply!(ch)

    assert_equal "active", ch.reload.status
    assert_not_nil ch.activated_at
  end

  test "a primary row takes over the domain's branding" do
    ch = manual_row(purpose: "primary")
    CustomHostnameActivation.apply!(ch)

    assert_equal ch.hostname, domains(:one).reload.active_custom_host
  end

  test "a migration row activates without ever becoming outbound branding" do
    ch = manual_row(purpose: "migration")
    CustomHostnameActivation.apply!(ch)

    assert_equal "active", ch.reload.status
    assert_nil domains(:one).reload.active_custom_host
  end

  test "is idempotent on an already active row and keeps the original activated_at" do
    ch = manual_row
    CustomHostnameActivation.apply!(ch)
    first_activated_at = ch.reload.activated_at

    travel(1.hour) { CustomHostnameActivation.apply!(ch) }

    assert_equal first_activated_at.to_i, ch.reload.activated_at.to_i
  end

  # A probe in flight while the operator deletes or replaces the row must not resurrect it.
  test "discards a stale result when the row was deleted mid-probe" do
    ch = manual_row
    ch.destroy!

    assert_nothing_raised { assert_not CustomHostnameActivation.apply!(ch) }
    assert_equal 0, CustomHostname.count
  end

  test "discards a stale result when the row left pending" do
    ch = manual_row
    CustomHostname.where(id: ch.id).update_all(status: "suspended")

    assert_not CustomHostnameActivation.apply!(ch)
    assert_equal "suspended", ch.reload.status
    assert_nil domains(:one).reload.active_custom_host
  end

  test "refuses a cloudflare row" do
    ch = manual_row
    ch.update_columns(cf_custom_hostname_id: "cf_1")

    assert_not CustomHostnameActivation.apply!(ch)
    assert_equal "pending", ch.reload.status
  end
end
