# frozen_string_literal: true

require "test_helper"

class Analytics::RetentionPolicyTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_subscriptions, :stripe_payment_intents, :projects

  test "cutoff_for resolves a project's queryable cutoff via its instance" do
    instances(:two).update!(cold_storage_days: 365, delete_days: 730) # free
    assert_equal Date.current - 365, Analytics::RetentionPolicy.cutoff_for(projects(:two).id)
  end

  test "cutoff_for returns nil for an unknown project" do
    assert_nil Analytics::RetentionPolicy.cutoff_for(0)
  end

  test "free instance: queryable window equals the cold boundary and cold access is blocked" do
    instance = instances(:two) # canceled sub, no enterprise -> free
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal :free, policy.plan
    assert_equal 365, policy.hot_days
    assert_equal 365, policy.queryable_days
    assert_not policy.can_query_cold
  end

  test "paid instance: queryable window equals delete_days and cold access is allowed" do
    instance = instances(:one) # active_sub -> paid
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal :paid, policy.plan
    assert_equal 365, policy.hot_days
    assert_equal 730, policy.queryable_days
    assert policy.can_query_cold
  end

  test "paused stripe subscription is treated as paid and keeps cold access" do
    instance = instances(:two)
    instance.update!(cold_storage_days: 365, delete_days: 730)
    StripeSubscription.create!(
      instance: instance,
      stripe_payment_intent: stripe_payment_intents(:two),
      subscription_id: "sub_paused_001",
      status: "paused",
      active: false,
      customer_id: "cus_paused"
    )

    policy = Analytics::RetentionPolicy.for(instance.reload)

    assert_equal :paid, policy.plan
    assert policy.can_query_cold
    assert_equal 730, policy.queryable_days
  end

  test "enterprise instance within its term: custom delete_days, cold allowed" do
    instance = instances(:two)
    instance.update!(cold_storage_days: 365, delete_days: 1825)
    EnterpriseSubscription.create!(
      instance: instance, active: true, total_maus: 100_000,
      start_date: 1.day.ago, end_date: 1.year.from_now
    )

    policy = Analytics::RetentionPolicy.for(instance.reload)

    assert_equal :enterprise, policy.plan
    assert policy.can_query_cold
    assert_equal 1825, policy.queryable_days
  end

  test "expired enterprise subscription (active flag true, term ended) loses cold access" do
    instance = instances(:two)
    instance.update!(cold_storage_days: 365, delete_days: 1825)
    EnterpriseSubscription.create!(
      instance: instance, active: true, total_maus: 100_000,
      start_date: 2.years.ago, end_date: 1.day.ago
    )

    policy = Analytics::RetentionPolicy.for(instance.reload)

    assert_equal :free, policy.plan
    assert_not policy.can_query_cold
    assert_equal 365, policy.queryable_days
  end

  test "self-hosted: own plan, full retention without any subscription" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    instance = instances(:two) # no active sub -> would be free on SaaS
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal :self_hosted, policy.plan
    assert policy.can_query_cold
    assert_equal 730, policy.queryable_days
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
  end

  test "self-hosted flag off keeps SaaS free-plan behavior" do
    instance = instances(:two)
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal :free, policy.plan
    assert_equal 365, policy.queryable_days
  end

  test "queryable_cutoff_date is today minus queryable_days" do
    instance = instances(:two)
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal Date.current - 365, policy.queryable_cutoff_date
  end

  test "cold_cutoff_date is today minus hot_days regardless of plan" do
    instance = instances(:one) # paid
    instance.update!(cold_storage_days: 365, delete_days: 730)

    policy = Analytics::RetentionPolicy.for(instance)

    assert_equal Date.current - 365, policy.cold_cutoff_date
  end
end
