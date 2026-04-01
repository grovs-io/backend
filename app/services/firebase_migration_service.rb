require "csv"

class FirebaseMigrationService
  def initialize(project:, deeplink_prefix: nil, short_link_prefix: nil)
    @project = project
    @domain = project.domain
    @deeplink_prefix = deeplink_prefix
    @short_link_prefix = short_link_prefix
  end

  # Returns { created_count:, skipped_count:, skipped:, links: }
  def import_csv(file_path)
    created = []
    skipped = []

    CSV.foreach(file_path, headers: true) do |row|
      link_name    = row["name"].to_s.strip
      short_link   = row["short_link"].to_s.strip
      utm_campaign = row["utm_campaign"].to_s.strip
      utm_medium   = row["utm_medium"].to_s.strip
      utm_source   = row["utm_source"].to_s.strip
      deeplink_url = row["link"].to_s.strip

      deeplink_url = @deeplink_prefix ? deeplink_url.gsub(@deeplink_prefix, uri_scheme_from_prefix(@deeplink_prefix)) : deeplink_url
      path = @short_link_prefix ? short_link.gsub(@short_link_prefix, "").strip : short_link.strip

      if path.blank?
        skipped << { reason: "blank_path", name: link_name, path: path }
        next
      end

      if Link.exists?(domain: @domain, path: path)
        skipped << { reason: "duplicate_on_domain", name: link_name, path: path }
        next
      end

      link = Link.new(
        name: link_name,
        path: path,
        generated_from_platform: "dashboard",
        domain: @domain,
        active: true,
        redirect_config: @project.redirect_config
      )
      link.tracking_campaign = utm_campaign
      link.tracking_medium   = utm_medium
      link.tracking_source   = utm_source
      link.data = { "appLink" => deeplink_url }

      link.save!
      created << link
    end

    {
      created_count: created.size,
      skipped_count: skipped.size,
      skipped: skipped,
      links: created
    }
  end

  private

  # Converts "https://myapp/" to "myapp://"
  def uri_scheme_from_prefix(prefix)
    "#{prefix.gsub(%r{\Ahttps?://}, '').gsub(%r{/\z}, '')}://"
  end
end
