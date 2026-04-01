require 'httparty'

class AppstoreService

  class << self
    def fetch_image_and_title_for_identifier(bundle_id)
      empty_response = {title: nil, image: nil}
      unless bundle_id
        return empty_response
      end

      title_key = redis_title_key(bundle_id)
      appstore_id_key = redis_appstore_key(bundle_id)

      title, appstore_id = REDIS.with do |conn|
        conn.pipelined do |p|
          p.get(title_key)
          p.get(appstore_id_key)
        end
      end

      if title.nil?
        result = get_image_title_id_online(bundle_id)

        title = result[:title]
        appstore_id = result[:id]

        REDIS.with do |conn|
          conn.pipelined do |p|
            p.set(title_key, title, ex: 24 * 3600)
            p.set(appstore_id_key, appstore_id, ex: 24 * 3600)
          end
        end
      end

      store_image = StoreImage.find_by(identifier: bundle_id, platform: Grovs::Platforms::IOS)
      if store_image.nil? || store_image.created_at < 24.hours.ago
        store_image = create_new_store_image(bundle_id, store_image)
      end

      {title: title, image: store_image&.image_access_url, appstore_id: appstore_id}
    end

    private

    def create_new_store_image(bundle_id, old_image)
      result = get_image_title_id_online(bundle_id)
      return nil if result.blank? || result[:image].blank?

      store_image = nil
      ActiveRecord::Base.transaction do
        if old_image
          old_image.destroy!
        end

        store_image = StoreImage.create!(identifier: bundle_id, platform: Grovs::Platforms::IOS)

        response = HTTParty.get(result[:image])
        downloaded_file = StringIO.new(response.body)
        store_image.image.attach(io: downloaded_file, filename: "#{bundle_id}.jpg", content_type: 'image/jpg')
      end

      store_image
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