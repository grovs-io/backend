# frozen_string_literal: true

module GeoipService
  def self.lookup(ip, db: GEOIP_DB)
    return { country: '', city: '' } if ip.blank? || db.nil?

    result = db.lookup(ip)
    return { country: '', city: '' } unless result&.found?

    {
      country: result.country&.iso_code.to_s,
      city: result.city&.name.to_s
    }
  rescue StandardError => e
    Rails.logger.warn("GeoipService: lookup failed for #{ip} — #{e.class}: #{e.message}")
    { country: '', city: '' }
  end
end
