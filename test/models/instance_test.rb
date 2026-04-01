require "test_helper"

class InstanceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  setup do
    @user = User.create!(email: "instance-test@test.com", password: "password123")
  end

  # === api_key ===

  test "api_key is required" do
    instance = Instance.new(uri_scheme: "apitest")
    assert_not instance.valid?
    assert_includes instance.errors[:api_key], "can't be blank"
  end

  test "api_key is usable as a lookup key for authentication" do
    key = "myapp_#{SecureRandom.hex(8)}"
    Instance.create!(uri_scheme: "lookuptest", api_key: key)
    found = Instance.find_by(api_key: key)
    assert_not_nil found
    assert_equal key, found.api_key
  end

  # === subscription ===

  test "subscription returns active subscription regardless of creation order" do
    instance = Instance.create!(uri_scheme: "subtest", api_key: "key-sub")
    spi = StripePaymentIntent.create!(user: @user, instance: instance, intent_id: "pi_1")
    # Create active FIRST, then paused — proves it's not returning last-created
    StripeSubscription.create!(instance: instance, stripe_payment_intent: spi, active: true, status: "active", subscription_id: "sub_active", 
customer_id: "cus_test_active")
    StripeSubscription.create!(instance: instance, stripe_payment_intent: spi, active: false, status: "paused", subscription_id: "sub_paused", 
customer_id: "cus_test_paused")

    result = instance.subscription
    assert_equal "sub_active", result.subscription_id
  end

  test "subscription returns paused when no active exists" do
    instance = Instance.create!(uri_scheme: "subtest2", api_key: "key-sub2")
    spi = StripePaymentIntent.create!(user: @user, instance: instance, intent_id: "pi_2")
    StripeSubscription.create!(instance: instance, stripe_payment_intent: spi, active: false, status: "canceled", subscription_id: "sub_canceled", 
customer_id: "cus_test_canceled")
    StripeSubscription.create!(instance: instance, stripe_payment_intent: spi, active: false, status: "paused", subscription_id: "sub_paused", 
customer_id: "cus_test_paused2")

    result = instance.subscription
    assert_equal "sub_paused", result.subscription_id
  end

  test "subscription returns nil when no subscriptions exist" do
    instance = Instance.create!(uri_scheme: "subtest3", api_key: "key-sub3")
    assert_nil instance.subscription
  end

  # === valid_enterprise_subscription ===

  test "valid_enterprise_subscription returns active enterprise subscription" do
    instance = Instance.create!(uri_scheme: "enttest", api_key: "key-ent")
    es = EnterpriseSubscription.create!(instance: instance, active: true, total_maus: 100_000, start_date: 1.month.ago, end_date: 1.month.from_now)

    assert_equal es, instance.valid_enterprise_subscription
  end

  test "valid_enterprise_subscription returns nil when subscription is inactive" do
    instance = Instance.create!(uri_scheme: "enttest2", api_key: "key-ent2")
    EnterpriseSubscription.create!(instance: instance, active: false, total_maus: 100_000, start_date: 1.month.ago, end_date: 1.month.from_now)

    assert_nil instance.valid_enterprise_subscription
  end

  # === application_for_platform ===

  test "application_for_platform creates application if none exists" do
    instance = Instance.create!(uri_scheme: "apptest", api_key: "key-app")

    assert_difference "Application.count", 1 do
      app = instance.application_for_platform(Grovs::Platforms::IOS)
      assert_equal Grovs::Platforms::IOS, app.platform
      assert_equal instance.id, app.instance_id
    end
  end

  test "application_for_platform returns existing application on second call" do
    instance = Instance.create!(uri_scheme: "apptest2", api_key: "key-app2")
    first = Application.create!(instance: instance, platform: Grovs::Platforms::ANDROID)

    # Bypass cache to avoid cross-process Redis interference
    Application.stub(:redis_find_by_multiple_conditions, lambda { |*args, **_kwargs|
      conditions = args.first
      Application.find_by(conditions)
    }) do
      assert_no_difference "Application.count" do
        result = instance.application_for_platform(Grovs::Platforms::ANDROID)
        assert_equal first.id, result.id
      end
    end
  end

  # === link_for_path ===

  test "link_for_path finds link in production domain first" do
    instance = Instance.create!(uri_scheme: "linktest", api_key: "key-link")
    prod_project = Project.create!(name: "Prod", identifier: "link-prod", instance: instance, test: false)
    test_project = Project.create!(name: "Test", identifier: "link-test", instance: instance, test: true)
    prod_domain = Domain.create!(domain: "prod.sqd.link", project: prod_project)
    Domain.create!(domain: "test.sqd.link", project: test_project)
    rc = RedirectConfig.create!(project: prod_project)

    link = Link.create!(domain: prod_domain, path: "abc123", redirect_config: rc, generated_from_platform: Grovs::Platforms::WEB)

    # Bypass cache so we hit the DB directly
    Link.stub(:redis_find_by_multiple_conditions, lambda { |conditions, **_kwargs|
      Link.find_by(conditions)
    }) do
      result = instance.reload.link_for_path("abc123")
      assert_equal link.id, result.id
    end
  end

  test "link_for_path falls back to test domain" do
    instance = Instance.create!(uri_scheme: "linktest2", api_key: "key-link2")
    prod_project = Project.create!(name: "Prod", identifier: "link-prod2", instance: instance, test: false)
    test_project = Project.create!(name: "Test", identifier: "link-test2", instance: instance, test: true)
    Domain.create!(domain: "prod2.sqd.link", project: prod_project)
    test_domain = Domain.create!(domain: "test2.sqd.link", project: test_project)
    rc = RedirectConfig.create!(project: test_project)

    link = Link.create!(domain: test_domain, path: "xyz789", redirect_config: rc, generated_from_platform: Grovs::Platforms::WEB)

    Link.stub(:redis_find_by_multiple_conditions, lambda { |conditions, **_kwargs|
      Link.find_by(conditions)
    }) do
      result = instance.reload.link_for_path("xyz789")
      assert_equal link.id, result.id
    end
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes uri_scheme lookup key" do
    instance = instances(:one)
    expected = "#{Instance.cache_prefix}:find_by:uri_scheme:#{instance.uri_scheme}:no_includes"
    assert_includes instance.cache_keys_to_clear, expected
  end

  test "cache_keys_to_clear invalidates both old and new uri_scheme on change" do
    instance = Instance.create!(uri_scheme: "old-scheme", api_key: "key-cache")
    instance.update!(uri_scheme: "new-scheme")

    keys = instance.cache_keys_to_clear
    prefix = Instance.cache_prefix
    assert_includes keys, "#{prefix}:find_by:uri_scheme:old-scheme:no_includes"
    assert_includes keys, "#{prefix}:find_by:uri_scheme:new-scheme:no_includes"
  end

  test "cache_keys_to_clear invalidates associated project identifier keys" do
    instance = instances(:one)
    project = projects(:one)
    project.update_columns(instance_id: instance.id, test: false)

    keys = instance.cache_keys_to_clear
    expected = "#{Project.cache_prefix}:find_by:identifier:#{project.identifier}:includes:instance"
    assert_includes keys, expected
  end

  # === create_desktop_configuration ===

  test "create_desktop_configuration creates desktop application and configuration when none exists" do
    instance = Instance.create!(uri_scheme: "desktest", api_key: "key-desk")

    # Bypass cache for application_for_platform
    Application.stub(:redis_find_by_multiple_conditions, lambda { |*args, **_kwargs|
      conditions = args.first
      Application.find_by(conditions)
    }) do
      assert_difference "DesktopConfiguration.count", 1 do
        instance.create_desktop_configuration
      end

      desktop_app = Application.find_by(instance_id: instance.id, platform: Grovs::Platforms::DESKTOP)
      assert_not_nil desktop_app
      assert_not_nil desktop_app.desktop_configuration
    end
  end

  test "create_desktop_configuration does not duplicate when configuration already exists" do
    instance = Instance.create!(uri_scheme: "desktest2", api_key: "key-desk2")

    Application.stub(:redis_find_by_multiple_conditions, lambda { |*args, **_kwargs|
      conditions = args.first
      Application.find_by(conditions)
    }) do
      # Create the first time
      instance.create_desktop_configuration

      # Second call should not create another
      assert_no_difference "DesktopConfiguration.count" do
        instance.create_desktop_configuration
      end
    end
  end

  # === execute_before_destroy callback ===

  test "destroying instance destroys ios and android configurations" do
    instance = Instance.create!(uri_scheme: "destroytest", api_key: "key-destroy")
    ios_app = Application.create!(instance: instance, platform: Grovs::Platforms::IOS)
    android_app = Application.create!(instance: instance, platform: Grovs::Platforms::ANDROID)
    ios_config = IosConfiguration.create!(application: ios_app, bundle_id: "com.test.destroy", app_prefix: "DEL123")
    android_config = AndroidConfiguration.create!(application: android_app, identifier: "com.test.destroy.android")

    instance.destroy!

    assert_not IosConfiguration.exists?(ios_config.id)
    assert_not AndroidConfiguration.exists?(android_config.id)
  end

  test "destroying instance destroys all applications" do
    instance = Instance.create!(uri_scheme: "destroytest2", api_key: "key-destroy2")
    app1 = Application.create!(instance: instance, platform: Grovs::Platforms::IOS)
    app2 = Application.create!(instance: instance, platform: Grovs::Platforms::ANDROID)

    instance.destroy!

    assert_not Application.exists?(app1.id)
    assert_not Application.exists?(app2.id)
  end

  test "destroying instance handles nil applications gracefully" do
    instance = Instance.create!(uri_scheme: "destroytest3", api_key: "key-destroy3")
    # No applications created — should not raise

    assert_nothing_raised do
      instance.destroy!
    end
    assert_not Instance.exists?(instance.id)
  end
end
