# GET https://onelink.appsflyer.com/api/v2.0/shortlinks/{onelink_id}/{shortlink_id}
# Credentials: { onelink_id, api_token }. Returns a MigrationLookupResult.
class AppsflyerMigrationClient
  BASE              = "https://onelink.appsflyer.com/api/v2.0/shortlinks".freeze
  REQUEST_TIMEOUT   = 3
  PROBE_SLUG_PREFIX = "__grovs_setup_probe_".freeze

  def initialize(source)
    @source = source
  end

  # query_string is intentionally NOT forwarded. AppsFlyer's endpoint has no slot for it
  # (unlike Branch's url= param) and it would just land in their request logs. The query
  # still rides on the 301 redirect target so attribution flows through.
  def fetch(old_path, query_string: "")
    # AppsFlyer short links are <host>/<onelink-id>/<shortlink-id>. The migration host path
    # carries both segments, but the API wants only the trailing shortlink-id (onelink-id
    # comes from credentials). Take the last segment; single-segment paths pass through.
    shortlink_id = old_path.to_s.split("/").reject(&:blank?).last.to_s
    # URL-encode the segment — a shortlink-id with #, ?, spaces would otherwise change the upstream path.
    response = HTTParty.get(
      "#{BASE}/#{ERB::Util.url_encode(onelink_id.to_s)}/#{ERB::Util.url_encode(shortlink_id)}",
      headers: auth_headers,
      timeout: REQUEST_TIMEOUT
    )
    map_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, HTTParty::Error => e
    Rails.logger.warn(message: "appsflyer_migration_client_network_error", source_id: @source.id, error: e.message)
    MigrationLookupResult.transient_error(http_status: 0)
  end

  def probe
    fetch("#{PROBE_SLUG_PREFIX}#{SecureRandom.hex(8)}__")
  end

  private

  def credentials = @source.credentials.is_a?(Hash) ? @source.credentials : {}
  def onelink_id  = credentials["onelink_id"]
  def api_token   = credentials["api_token"]
  def auth_headers = { "Authorization" => "Bearer #{api_token}", "Accept" => "application/json" }

  def map_response(response)
    case response.code
    when 200 then MigrationLookupResult.found(parse_payload(response), http_status: 200)
    when 404 then MigrationLookupResult.not_found(http_status: 404)
    when 400, 401, 403, 429, 500..599
      MigrationLookupResult.transient_error(
        http_status: response.code,
        retry_after: response.headers["retry-after"]
      )
    else
      MigrationLookupResult.transient_error(http_status: response.code)
    end
  end

  # AppsFlyer canonical mapping (af.com/hc/en-us/articles/207447163):
  #   c → campaign, pid → source, af_channel → medium, af_ad → name.
  # af_ad must NOT bind to tracking_* — that would produce meaningless aggregations.
  def parse_payload(response)
    body = response.parsed_response
    body = JSON.parse(body) if body.is_a?(String)
    data = body.is_a?(Hash) ? body : {}

    consumed = %w[af_dp af_web_dp af_ios_url af_android_url af_ad af_channel pid c
                  af_og_title af_og_description af_og_image af_title af_subtitle]
    custom_data = data.reject { |k, _| consumed.include?(k) }

    ios_url     = data["af_ios_url"]     || data["af_dp"]
    android_url = data["af_android_url"] || data["af_dp"]

    {
      "ios_url"           => ios_url,
      "android_url"       => android_url,
      "desktop_url"       => data["af_web_dp"],
      "og_title"          => data["af_og_title"] || data["af_title"],
      "og_description"    => data["af_og_description"] || data["af_subtitle"],
      "og_image_url"      => data["af_og_image"],
      "tracking_campaign" => data["c"],
      "tracking_source"   => data["pid"],
      "tracking_medium"   => data["af_channel"],
      "tags"              => [],
      "name"              => data["af_ad"] || data["af_title"],
      "provider"          => Grovs::Migrations::PROVIDER_APPSFLYER,
      "custom_data"       => custom_data
    }
  rescue JSON::ParserError => e
    Rails.logger.warn(message: "appsflyer_migration_client_parse_error", source_id: @source.id, error: e.message)
    { "provider" => Grovs::Migrations::PROVIDER_APPSFLYER, "custom_data" => {} }
  end
end
