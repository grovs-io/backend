# frozen_string_literal: true

GEOIP_DB = begin
  path = Pathname.new(ENV.fetch('GEOIP_DB_PATH', Rails.root.join('db/GeoLite2-City.mmdb').to_s))
  if File.exist?(path)
    MaxMindDB.new(path.to_s)
  else
    Rails.logger.warn("GeoIP database not found at #{path} — geo features disabled")
    nil
  end
end
