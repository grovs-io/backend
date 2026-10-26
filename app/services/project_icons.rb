# iOS App Store artwork, else Android Play artwork; stored copies only, stale ones refreshed in the background.
module ProjectIcons
  PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID].freeze
  REDIS_ERRORS = [Redis::BaseError, RedisClient::Error, ConnectionPool::TimeoutError].freeze

  module_function

  # { instance_id => url or nil } for the whole list in a fixed number of queries.
  def for(instances)
    ids = instances.map(&:id)
    apps = app_identifiers(ids)
    images = StoreImage.with_attached_image.where(identifier: apps.map(&:last).uniq).index_by { |i| [i.platform, i.identifier] }

    refresh(apps.map { |_, platform, identifier| [platform, identifier] }.uniq.select { |key| stale?(images[key]) })
    ids.index_with do |id|
      mine = apps.select { |instance_id, _, _| instance_id == id }.sort_by { |_, platform, _| PLATFORMS.index(platform) }
      mine.lazy.map { |_, platform, identifier| images[[platform, identifier]] }.find { |i| i&.image&.attached? }&.image_access_url
    end
  end

  def app_identifiers(instance_ids)
    ios = Application.joins(:ios_configuration).where(instance_id: instance_ids, platform: Grovs::Platforms::IOS, enabled: true)
                     .where.not(ios_configurations: { bundle_id: [nil, ""] }).pluck(:instance_id, "ios_configurations.bundle_id")
    android = Application.joins(:android_configuration).where(instance_id: instance_ids, platform: Grovs::Platforms::ANDROID, enabled: true)
                         .where.not(android_configurations: { identifier: [nil, ""] }).pluck(:instance_id, "android_configurations.identifier")
    ios.map { |id, bundle| [id, Grovs::Platforms::IOS, bundle] } + android.map { |id, identifier| [id, Grovs::Platforms::ANDROID, identifier] }
  end

  def stale?(image)
    image.nil? || image.created_at < 24.hours.ago
  end

  # A 24h mark per app, so artwork the store doesn't have isn't re-scraped on every page load.
  def refresh(apps)
    return if apps.empty?

    fresh = REDIS.with do |redis|
      redis.pipelined { |p| apps.each { |platform, id| p.set("project_icon_refresh:#{platform}:#{id}", "1", nx: true, ex: 1.day.to_i) } }
    end
    apps.zip(fresh).each { |(platform, id), won| RefreshStoreMetadataJob.perform_async(platform, id) if won }
  rescue *REDIS_ERRORS => e
    Rails.logger.warn(message: "project_icon_refresh_failed", error: e.message)
  end
end
