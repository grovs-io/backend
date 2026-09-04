require 'nokogiri'

class GooglePlayService

  class << self
    def fetch_image_and_title_for_identifier(identifier)
      return {title: nil, image: nil} unless identifier

      title = REDIS.get(redis_title_key(identifier))
      store_image = StoreImage.find_by(identifier: identifier, platform: Grovs::Platforms::ANDROID)

      if title.nil? || store_image.nil? || store_image.created_at < 24.hours.ago
        enqueue_refresh(identifier)
      end

      {title: title, image: store_image&.image_access_url}
    end

    def refresh!(identifier)
      return unless identifier

      result = get_image_and_title_online(identifier)
      return unless result

      # Download the artwork BEFORE writing the cache: if the download fails transiently
      # we must not pin a title-with-no-image entry for 24h (fetch_* would stop retrying).
      image_bytes = nil
      if result[:image].present?
        image_bytes = download_image(result[:image])
        return if image_bytes.nil? # transient download failure — cache nothing, retry later
      end

      REDIS.set(redis_title_key(identifier), result[:title], ex: 24 * 3600)

      return if image_bytes.nil? # app genuinely has no artwork — title cached, done

      # Idempotent: reuse the single (identifier, platform) row and re-attach so concurrent
      # refreshes can't leave duplicate StoreImage rows (destroy+create always would). A DB
      # unique index on (identifier, platform) would fully close the narrow create race.
      store_image = StoreImage.find_or_create_by!(identifier: identifier, platform: Grovs::Platforms::ANDROID)
      store_image.image.purge if store_image.image.attached?
      store_image.image.attach(io: StringIO.new(image_bytes), filename: "#{identifier}.jpg", content_type: 'image/jpg')
      # Restart the 24h freshness window (fetch_* keys off created_at) on the reused row.
      store_image.update_column(:created_at, Time.current)
    end

    private

    def download_image(url)
      response = HTTParty.get(url)
      return nil unless response.code == 200

      response.body
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError,
           Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("GooglePlayService: failed to download image #{url}: #{e.class} - #{e.message}")
      nil
    end

    def enqueue_refresh(identifier)
      return unless REDIS.set("store_meta_refresh:android:#{identifier}", "1", nx: true, ex: 300)

      RefreshStoreMetadataJob.perform_async(Grovs::Platforms::ANDROID, identifier)
    end

    def get_image_and_title_online(identifier)
      begin
        response = HTTParty.get("https://play.google.com/store/apps/details?id=#{identifier}&hl=en&gl=US")
        doc = Nokogiri::HTML5(response.body)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError,
             Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
        Rails.logger.warn("GooglePlayService: failed to fetch app page for #{identifier}: #{e.class} - #{e.message}")
        return nil
      end

      # Search for nodes by css
      image_urls = []
      titles = []

      collect_image_urls(doc, image_urls)
      collect_h1_tags(doc, titles)

      image_url = image_urls.uniq.filter{|img| img.end_with?("w240-h480")}.first
      title = titles.uniq.first

      {image: image_url, title: title}
    end

    def collect_image_urls(node, image_urls)
      node.css('img').each do |img|
        image_urls << img['src'] if img['src'].present?
      end

      node.children.each do |child|
        collect_image_urls(child, image_urls) if child.element?
      end
    end

    def collect_h1_tags(node, h1_tags)
      node.css('h1').each do |h1|
        h1_tags << h1.text.strip if h1.text.present?
      end

      node.children.each do |child|
        collect_h1_tags(child, h1_tags) if child.element?
      end
    end

    def redis_image_key(identifier)
      "#{Grovs::RedisKeys::IMAGE_PREFIX}-android-#{identifier}"
    end

    def redis_title_key(identifier)
      "#{Grovs::RedisKeys::TITLE_PREFIX}-android-#{identifier}"
    end
  end

end