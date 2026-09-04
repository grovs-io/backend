# Translates an upstream payload into a native Grovs Link + per-platform CustomRedirect rows.
# Returns nil on missing domain/redirect_config or an exhausted path namespace; FirstHitMigration
# treats nil as "couldn't materialize" and serves project defaults.
class MigratedLinkBuilder
  MAX_CUSTOM_DATA_BYTES = 65_536
  MAX_TAG_COUNT         = 100
  MAX_TAG_LENGTH        = 255

  # Web URLs render in a browser — strict http/https blocks javascript:/data: XSS.
  # Mobile URLs go to the OS app-open mechanism — custom URI schemes (myapp://) are
  # the foundation of deep linking, so we use a deny-list instead.
  WEB_SCHEMES              = %w[http https].freeze
  DANGEROUS_MOBILE_SCHEMES = %w[javascript data file vbscript about].freeze

  def self.call(project:, payload:)
    unless project.domain && project.redirect_config
      Rails.logger.warn(
        message: "migrated_link_builder_missing_prerequisites",
        project_id: project.id,
        has_domain: project.domain.present?,
        has_redirect_config: project.redirect_config.present?
      )
      return nil
    end

    Link.transaction do
      domain = project.domain
      link = Link.create!(
        domain: domain,
        redirect_config: project.redirect_config,
        path: LinksService.generate_valid_path(domain),
        generated_from_platform: Grovs::Migrations::GENERATED_FROM_PLATFORM,
        active: true,
        name:     payload["name"].presence || default_name(payload),
        title:    payload["og_title"].presence,
        subtitle: payload["og_description"].presence,
        image_url: scrub_web_url(payload["og_image_url"]),
        tracking_campaign: payload["tracking_campaign"],
        tracking_source:   payload["tracking_source"],
        tracking_medium:   payload["tracking_medium"],
        tags: cap_tags(payload["tags"]),
        data: cap_custom_data(payload["custom_data"])
      )

      build_mobile_redirect(link, Grovs::Platforms::IOS,     payload["ios_url"])
      build_mobile_redirect(link, Grovs::Platforms::ANDROID, payload["android_url"])
      build_web_redirect(link,    Grovs::Platforms::DESKTOP, payload["desktop_url"])

      link
    end
  rescue LinksService::PathGenerationError => e
    # Public redirect: nil degrades to project defaults, where raising would be a bare 500.
    Rails.logger.error(message: "migrated_link_builder_path_exhausted",
                       project_id: project.id, error: e.message)
    nil
  end

  def self.build_mobile_redirect(link, platform, url)
    safe = scrub_mobile_url(url)
    return if safe.blank?
    CustomRedirect.create!(link: link, platform: platform, url: safe, open_app_if_installed: true)
  end

  def self.build_web_redirect(link, platform, url)
    safe = scrub_web_url(url)
    return if safe.blank?
    CustomRedirect.create!(link: link, platform: platform, url: safe, open_app_if_installed: true)
  end

  def self.scrub_web_url(url)
    return nil if url.blank?
    parsed = URI.parse(url.to_s)
    return nil unless WEB_SCHEMES.include?(parsed.scheme&.downcase)
    return nil if parsed.host.blank?
    url
  rescue URI::InvalidURIError
    Rails.logger.warn(message: "migrated_link_builder_invalid_url", url: url)
    nil
  end

  def self.scrub_mobile_url(url)
    return nil if url.blank?
    parsed = URI.parse(url.to_s)
    scheme = parsed.scheme&.downcase
    return nil if scheme.blank?
    return nil if DANGEROUS_MOBILE_SCHEMES.include?(scheme)
    url
  rescue URI::InvalidURIError
    Rails.logger.warn(message: "migrated_link_builder_invalid_url", url: url)
    nil
  end

  def self.default_name(payload)
    "Migrated from #{payload['provider'] || 'upstream'}"
  end

  # Drop the whole hash if it exceeds the cap (partial JSON is untrustworthy).
  def self.cap_custom_data(custom_data)
    return {} if custom_data.blank?
    return custom_data if custom_data.is_a?(Hash) && custom_data.to_json.bytesize <= MAX_CUSTOM_DATA_BYTES
    Rails.logger.warn(
      message: "migrated_link_builder_custom_data_oversize",
      bytesize: custom_data.to_json.bytesize,
      max: MAX_CUSTOM_DATA_BYTES
    )
    {}
  end

  # Truncate by character (NOT byte) to keep UTF-8 valid for PG text[] inserts.
  def self.cap_tags(tags)
    return [] if tags.blank?
    Array(tags)
      .select { |t| t.is_a?(String) && t.length.positive? }
      .first(MAX_TAG_COUNT)
      .map { |t| t.each_char.first(MAX_TAG_LENGTH).join }
  end
end
