module SmartBannerLinkService
  MAX_LINKS = 10_000
  NEW_LINK_RATE_LIMIT_PER_MINUTE = 120

  class RateLimited < StandardError; end

  module_function

  def max_links
    MAX_LINKS
  end

  def new_link_rate_limit
    NEW_LINK_RATE_LIMIT_PER_MINUTE
  end

  def create_default_link!(banner)
    link = create_link!(banner, {})
    banner.update!(default_link: link)
    link
  end

  def fetch(banner, page_path:, data:, client_ip: nil)
    canonical = SmartBannerLinkData.build(page_path: page_path, data: data)
    data_hash = SmartBannerLinkData.digest(canonical)
    found = existing_link(banner, data_hash)
    return found if found
    # Soft cap: concurrent creators may overshoot it slightly.
    return banner.default_link if banner.links_count >= max_links
    raise RateLimited unless new_link_rate_limit_ok?(banner, client_ip)

    create_page_link!(banner, canonical, data_hash)
  rescue ActiveRecord::RecordNotUnique
    existing_link(banner, data_hash) || raise
  end

  # Fixed 60s window starting at the first new-link request per banner+IP; fails open on Redis errors.
  def new_link_rate_limit_ok?(banner, client_ip)
    return true if client_ip.blank?

    key = "smart_banner:new_link_rate:#{banner.id}:#{client_ip}"
    count = REDIS.with do |c|
      # redis gem 4.8.1 + Redis 6 don't support EXPIRE NX; only the first INCR sets the TTL.
      n = c.incr(key)
      c.expire(key, 60) if n == 1
      n
    end
    count <= new_link_rate_limit
  rescue Redis::BaseError, ConnectionPool::TimeoutError => e
    Rails.logger.warn("smart_banner_new_link_rate_limit_check_failed: #{e.message}")
    true
  end

  def existing_link(banner, data_hash)
    SmartBannerLink.includes(link: :domain).find_by(smart_banner_id: banner.id, data_hash: data_hash)&.link
  end

  # One transaction so a lost unique-index race rolls back its Link too.
  def create_page_link!(banner, canonical, data_hash)
    ActiveRecord::Base.transaction do
      link = create_link!(banner, canonical)
      SmartBannerLink.create!(smart_banner: banner, data_hash: data_hash, link: link)
      link
    end
  end

  def create_link!(banner, data)
    SdkLinkCreationService.create(
      project: banner.project, platform: SmartBanner::LINK_PLATFORM, sdk_generated: false,
      data: data, tags: [SmartBanner::LINK_TAG, "smart_banner:#{banner.id}"],
      show_preview_ios: false, show_preview_android: false
    )
  end
end
