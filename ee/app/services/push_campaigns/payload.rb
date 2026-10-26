module PushCampaigns
  class Payload
    RESERVED = %w[grovs_campaign_id grovs_link grovs_image].freeze

    def initialize(campaign)
      @campaign = campaign
      @image = campaign.image_resource
    end

    def data
      base = { "grovs_campaign_id" => @campaign.hashid }
      base["grovs_link"] = @campaign.link.access_path if @campaign.link
      base["grovs_image"] = @image if @image.present?
      @campaign.data.to_h.stringify_keys.except(*RESERVED).merge(base)
    end

    # Sized against a throwaway app and token: the payload does not depend on either.
    def apns_bytesize(variant = nil)
      apns(Rpush::Apnsp8::App.new, "0" * 64, variant).payload.bytesize
    end

    def build(platform, app, token, variant = nil)
      case platform
      when Grovs::Platforms::IOS then apns(app, token, variant)
      when Grovs::Platforms::ANDROID then fcm(app, token, variant)
      else raise ArgumentError, "no push channel for #{platform}"
      end
    end

    private

    def apns(app, token, variant = nil)
      n = Rpush::Apnsp8::Notification.new
      n.app = app
      n.device_token = token
      n.alert = { "title" => @campaign.title_for(variant), "body" => @campaign.body_for(variant) }
      n.sound = @campaign.sound if @campaign.sound.present?
      n.mutable_content = @image.present?
      n.data = data
      n
    end

    def fcm(app, token, variant = nil)
      n = Rpush::Fcm::Notification.new
      n.app = app
      n.device_token = token
      notification = { "title" => @campaign.title_for(variant), "body" => @campaign.body_for(variant) }
      notification["image"] = @image if @image.present?
      n.notification = notification
      n.sound = @campaign.sound if @campaign.sound.present?
      n.data = data.transform_values { |v| v.is_a?(String) ? v : v.to_json } # FCM rejects non-string data values
      n
    end
  end
end
