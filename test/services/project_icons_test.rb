require "test_helper"
require "sidekiq/testing"

class ProjectIconsTest < ActiveSupport::TestCase
  fixtures :instances, :applications, :ios_configurations, :android_configurations

  setup do
    Sidekiq::Testing.fake!
    RefreshStoreMetadataJob.clear
    clear_refresh_marks("store_meta_refresh:*", "project_icon_refresh:*")
  end

  teardown { Sidekiq::Testing.disable! }

  def clear_refresh_marks(*patterns)
    REDIS.with { |c| patterns.flat_map { |p| c.keys(p) }.each { |k| c.del(k) } }
  end

  def icon(identifier, platform, created_at: Time.current)
    image = StoreImage.create!(identifier: identifier, platform: platform)
    image.image.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "#{identifier}.png", content_type: "image/png")
    image.update_column(:created_at, created_at)
    image.image_access_url
  end

  test "the App Store icon wins over the Play one" do
    ios = icon("com.test.iosapp", Grovs::Platforms::IOS)
    icon("com.test.androidapp", Grovs::Platforms::ANDROID)

    assert_equal({ instances(:one).id => ios }, ProjectIcons.for([instances(:one)]))
  end

  test "the Play icon when the iOS app has none or is switched off" do
    android = icon("com.test.androidapp", Grovs::Platforms::ANDROID)
    assert_equal android, ProjectIcons.for([instances(:one)])[instances(:one).id]

    icon("com.test.iosapp", Grovs::Platforms::IOS)
    applications(:ios_app).update!(enabled: false)
    assert_equal android, ProjectIcons.for([instances(:one)])[instances(:one).id]
  end

  test "no icon yet: nil, and at most one refresh per app a day" do
    assert_nil ProjectIcons.for([instances(:one)])[instances(:one).id]
    clear_refresh_marks("store_meta_refresh:*")
    ProjectIcons.for([instances(:one)])

    queued = RefreshStoreMetadataJob.jobs.map { |j| j["args"] }
    assert_equal [[Grovs::Platforms::IOS, "com.test.iosapp"], [Grovs::Platforms::ANDROID, "com.test.androidapp"]].sort, queued.sort
  end

  test "a stale icon is still shown while it is refreshed" do
    ios = icon("com.test.iosapp", Grovs::Platforms::IOS, created_at: 2.days.ago)

    assert_equal ios, ProjectIcons.for([instances(:one)])[instances(:one).id]
    assert_includes RefreshStoreMetadataJob.jobs.map { |j| j["args"] }, [Grovs::Platforms::IOS, "com.test.iosapp"]
  end

  test "Redis being down still returns the icons" do
    ios = icon("com.test.iosapp", Grovs::Platforms::IOS, created_at: 2.days.ago)
    down = ->(*) { raise Redis::CannotConnectError }
    REDIS.stub(:with, down) do
      REDIS.stub(:set, down) { assert_equal ios, ProjectIcons.for([instances(:one)])[instances(:one).id] }
    end
    RefreshStoreMetadataJob.stub(:perform_async, ->(*) { raise RedisClient::CannotConnectError }) do
      assert_equal ios, ProjectIcons.for([instances(:one)])[instances(:one).id]
    end
  end

  test "a whole list costs the same few queries whatever its length" do
    icon("com.test.iosapp", Grovs::Platforms::IOS)
    ProjectIcons.for(Instance.all.to_a)
    all = Instance.all.to_a
    first = instances(:one)
    one = ActiveRecord::Base.uncached { count_queries { ProjectIcons.for([first]) } }
    many = ActiveRecord::Base.uncached { count_queries { ProjectIcons.for(all) } }
    assert_equal one, many
  end

  def count_queries(&)
    n = 0
    counter = ->(*, payload) { n += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    n
  end
end
