require "test_helper"
require "rake"

class PushLoadTaskTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :android_push_configurations, :devices

  ENV_KEYS = %w[INSTANCE_ID CONFIRM PUSH_LOAD_ALLOW].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    %w[push_load:setup push_load:tokens].each { |t| Rake::Task[t].reenable }
    @saved = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["PUSH_LOAD_ALLOW"] = "1"
    PushLoad.instance_variable_set(:@instance, nil)
  end

  teardown do
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    REDIS.with { |c| c.scan_each(match: "#{Instance.cache_prefix}:find_by:id:*").each { |k| c.del(k) } } # fixture ids repeat across runs
    PushLoad.instance_variable_set(:@instance, nil)
  end

  def run_task(name, instance, confirm: true)
    ENV["INSTANCE_ID"] = instance.id.to_s
    confirm ? ENV["CONFIRM"] = instance.id.to_s : ENV.delete("CONFIRM")
    capture_io { Rake::Task[name].invoke }
  end

  def bulk_device(project, index, platform)
    Device.create!(vendor: "bulk-#{project.id}-#{index}", platform: platform, user_agent: "bulk-seed/#{platform}", ip: "10.0.0.9", remote_ip: "10.0.0.9")
  end

  test "setup refuses an instance with real push credentials" do
    instance = instances(:one)

    assert_raises(SystemExit) { run_task("push_load:setup", instance) }
    assert_equal "com.test.iosapp", ios_configurations(:one).reload.bundle_id
    assert_equal "my-firebase-project-12345", android_push_configurations(:one).reload.firebase_project_id
  end

  test "setup gives the instance sink-marked rpush apps" do
    instance = instances(:two)
    run_task("push_load:setup", instance)

    ios_app = RpushService.app_for_platform(Grovs::Platforms::IOS, instance.production)
    fcm_app = RpushService.app_for_platform(Grovs::Platforms::ANDROID, instance.production)
    assert ios_app.name.start_with?(PushSink::APP_PREFIX)
    assert fcm_app.name.start_with?(PushSink::APP_PREFIX)
    assert_equal PushSink::FIREBASE_PROJECT_ID, fcm_app.firebase_project_id
    assert_equal "io.grovs.pushload", ios_app.bundle_id, "a missing iOS config gets a placeholder"
  end

  test "setup keeps an existing app's bundle id and can run again" do
    instance = instances(:two)
    IosConfiguration.create!(application: applications(:second_ios_app), bundle_id: "com.demo.keep", app_prefix: "KEEP000001")
    run_task("push_load:setup", instance)
    Rake::Task["push_load:setup"].reenable
    PushLoad.instance_variable_set(:@instance, nil)
    run_task("push_load:setup", instance)

    assert_equal "com.demo.keep", RpushService.app_for_platform(Grovs::Platforms::IOS, instance.production).bundle_id
    assert_equal 1, Rpush::Apnsp8::App.where("name LIKE ?", "#{PushSink::APP_PREFIX}%-production").count
  end

  test "tokens needs CONFIRM" do
    project = instances(:one).production
    device = bulk_device(project, 1, "ios")

    assert_raises(SystemExit) { run_task("push_load:tokens", instances(:one), confirm: false) }
    assert_nil device.reload.push_token
  end

  test "tokens refuses an instance with real push credentials" do
    device = bulk_device(instances(:one).production, 1, "android")

    assert_raises(SystemExit) { run_task("push_load:tokens", instances(:one)) }
    assert_nil device.reload.push_token
  end

  test "tokens are deterministic and only reach the instance's bulk mobile devices" do
    project = instances(:two).production
    ios = bulk_device(project, 1, "ios")
    android = bulk_device(project, 2, "android")
    web = bulk_device(project, 3, "web")
    other = bulk_device(instances(:one).production, 1, "ios")

    run_task("push_load:tokens", instances(:two))

    assert_equal Digest::SHA256.hexdigest(ios.vendor), ios.reload.push_token
    assert_equal "plfcm-#{Digest::SHA256.hexdigest(android.vendor)}", android.reload.push_token
    assert_nil web.reload.push_token
    assert_nil other.reload.push_token
    assert_nil devices(:ios_device).reload.push_token
  end
end
