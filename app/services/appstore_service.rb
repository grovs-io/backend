require 'httparty'

class AppstoreService

  class << self
    def fetch_image_and_title_for_identifier(bundle_id)
      return {title: nil, image: nil} unless bundle_id

      title, appstore_id = REDIS.with do |conn|
        conn.pipelined do |p|
          p.get(redis_title_key(bundle_id))
          p.get(redis_appstore_key(bundle_id))
        end
      end

      store_image = StoreImage.find_by(identifier: bundle_id, platform: Grovs::Platforms::IOS)

      if title.nil? || store_image.nil? || store_image.created_at < 24.hours.ago
        enqueue_refresh(bundle_id)
      end

      {title: title, image: store_image&.image_access_url, appstore_id: appstore_id}
    end

    def refresh!(bundle_id)
      return unless bundle_id

      result = get_image_title_id_online(bundle_id)

      # Download the artwork BEFORE writing the cache: if the download fails transiently
      # we must not pin a title-with-no-image entry for 24h (fetch_* would stop retrying).
      image_bytes = nil
      if result[:image].present?
        image_bytes = download_image(result[:image])
        return if image_bytes.nil? # transient download failure — cache nothing, retry later
      end

      REDIS.with do |conn|
        conn.pipelined do |p|
          p.set(redis_title_key(bundle_id), result[:title], ex: 24 * 3600)
          p.set(redis_appstore_key(bundle_id), result[:id], ex: 24 * 3600)
        end
      end

      return if image_bytes.nil? # app genuinely has no artwork — title cached, done

      # Idempotent: reuse the single (identifier, platform) row and re-attach so concurrent
      # refreshes can't leave duplicate StoreImage rows (destroy+create always would). A DB
      # unique index on (identifier, platform) would fully close the narrow create race.
      store_image = StoreImage.find_or_create_by!(identifier: bundle_id, platform: Grovs::Platforms::IOS)
      store_image.image.purge if store_image.image.attached?
      store_image.image.attach(io: StringIO.new(image_bytes), filename: "#{bundle_id}.jpg", content_type: 'image/jpg')
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
      Rails.logger.warn("AppstoreService: failed to download image #{url}: #{e.class} - #{e.message}")
      nil
    end

    def enqueue_refresh(bundle_id)
      return unless REDIS.set("store_meta_refresh:ios:#{bundle_id}", "1", nx: true, ex: 300)

      RefreshStoreMetadataJob.perform_async(Grovs::Platforms::IOS, bundle_id)
    end

    def get_image_title_id_online(bundle_id)
      empty_response = {title: nil, image: nil}

      response = HTTParty.get("https://itunes.apple.com/lookup?bundleId=#{bundle_id}")
      if response.code != 200
        # We have an error!
        return empty_response
      end

      json_response = JSON.parse response.body

      if json_response['results'].count > 0
        first_result = json_response['results'][0]
        title = first_result["trackName"]
        image = first_result["artworkUrl512"]
        id = first_result["trackId"]

        return {title: title, image: image, id: id}
      end

      empty_response
    end

    def redis_image_key(bundle_id)
      "#{Grovs::RedisKeys::IMAGE_PREFIX}-ios-#{bundle_id}"
    end

    def redis_title_key(bundle_id)
      "#{Grovs::RedisKeys::TITLE_PREFIX}-ios-#{bundle_id}"
    end

    def redis_appstore_key(bundle_id)
      "#{Grovs::RedisKeys::APPSTORE_PREFIX}-ios-#{bundle_id}"
    end
  end

end