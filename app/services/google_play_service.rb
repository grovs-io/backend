require 'nokogiri'

class GooglePlayService

  class << self
    def fetch_image_and_title_for_identifier(identifier)
      empty_response = {title: nil, image: nil}

      unless identifier
        return empty_response
      end

      title_key = redis_title_key(identifier)

      title = REDIS.get(title_key)

      if title.nil?
        result = get_image_and_title_online(identifier)
        unless result
          return empty_response
        end

        title = result[:title]

        REDIS.set(title_key, title, ex: 24 * 3600)
      end

      store_image = StoreImage.find_by(identifier: identifier, platform: Grovs::Platforms::ANDROID)
      if store_image.nil? || store_image.created_at < 24.hours.ago
        store_image = create_new_store_image(identifier, store_image)
      end

      {title: title, image: store_image&.image_access_url}
    end

    private

    def create_new_store_image(identifier, old_image)
      result = get_image_and_title_online(identifier)
      return nil if result.blank? || result[:image].blank?

      store_image = nil
      ActiveRecord::Base.transaction do
        if old_image
          old_image.destroy!
        end

        store_image = StoreImage.create!(identifier: identifier, platform: Grovs::Platforms::ANDROID)

        response = HTTParty.get(result[:image])
        downloaded_file = StringIO.new(response.body)
        store_image.image.attach(io: downloaded_file, filename: "#{identifier}.jpg", content_type: 'image/jpg')
      end

      store_image
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