class SmartBannerSerializer < BaseSerializer
  EMPTY_STATS = { "views" => 0, "clicks" => 0, "dismisses" => 0, "ctr" => 0.0, "opens" => 0, "installs" => 0 }.freeze
  SDK_ATTRIBUTES = %w[id platforms url_include url_exclude position title subtitle button_text
                      background_color text_color button_color button_text_color dismiss_days open_hide_days].freeze

  attributes :id, :name, :status, :priority, :platforms, :url_include, :url_exclude, :position,
             :title, :subtitle, :button_text, :background_color, :text_color, :button_color,
             :button_text_color, :dismiss_days, :open_hide_days, :created_at, :updated_at

  def self.sdk(banner)
    return nil unless banner.default_link

    banner.attributes.slice(*SDK_ATTRIBUTES).merge(links_and_icon(banner))
  end

  def self.links_and_icon(banner)
    { "icon_url" => AssetService.permanent_url(banner.icon), "default_link" => banner.default_link&.access_path }
  end

  def build(stats: EMPTY_STATS, **)
    super().merge(self.class.links_and_icon(record), "stats" => stats)
  end
end
