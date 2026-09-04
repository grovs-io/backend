require "uri"

# GET https://api2.branch.io/v1/url?url=<full_old_url>&branch_key=<key>
# Returns a MigrationLookupResult. Stateless; counters live on the MigrationSource model.
class BranchMigrationClient
  ENDPOINT          = "https://api2.branch.io/v1/url".freeze
  REQUEST_TIMEOUT   = 3
  PROBE_SLUG_PREFIX = "__grovs_setup_probe_".freeze

  def initialize(source)
    @source = source
  end

  def fetch(old_path, query_string: "")
    full_url = build_full_url(old_path, query_string)
    response = HTTParty.get(
      ENDPOINT,
      query: { url: full_url, branch_key: branch_key },
      timeout: REQUEST_TIMEOUT
    )
    map_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, HTTParty::Error => e
    Rails.logger.warn(message: "branch_migration_client_network_error", source_id: @source.id, error: e.message)
    MigrationLookupResult.transient_error(http_status: 0)
  end

  # Random sentinel so the DB sequence value isn't leaked upstream and collisions stay astronomically rare.
  def probe
    fetch("#{PROBE_SLUG_PREFIX}#{SecureRandom.hex(8)}__")
  end

  private

  def branch_key
    @source.credentials.is_a?(Hash) ? @source.credentials["branch_key"] : nil
  end

  def build_full_url(old_path, query_string)
    base = "https://#{@source.old_host}/#{old_path}"
    query_string.to_s.empty? ? base : "#{base}?#{query_string}"
  end

  def map_response(response)
    case response.code
    when 200 then MigrationLookupResult.found(parse_payload(response), http_status: 200)
    when 404 then MigrationLookupResult.not_found(http_status: 404)
    when 401, 403, 429, 500..599
      MigrationLookupResult.transient_error(
        http_status: response.code,
        retry_after: response.headers["retry-after"]
      )
    else
      MigrationLookupResult.transient_error(http_status: response.code)
    end
  end

  # Branch's data blob is sometimes a Hash, sometimes a JSON string. After parsing,
  # coerce to {} for any non-Hash so subsequent data["$ios_url"] can't TypeError on
  # adversarial responses like {"data": "[]"}.
  def parse_payload(response)
    body = response.parsed_response
    body = JSON.parse(body) if body.is_a?(String)
    data = body.is_a?(Hash) ? (body["data"] || body) : {}
    data = JSON.parse(data) if data.is_a?(String)
    data = {} unless data.is_a?(Hash)

    consumed = %w[
      $ios_url $android_url $desktop_url
      $og_title $og_description $og_image_url
      $link_title $marketing_title
      ~campaign ~channel ~feature ~stage ~tags
      utm_campaign utm_source utm_medium
    ]
    custom_data = data.reject { |k, _| consumed.include?(k) }

    {
      "ios_url"           => data["$ios_url"],
      "android_url"       => data["$android_url"],
      "desktop_url"       => data["$desktop_url"],
      "og_title"          => data["$og_title"],
      "og_description"    => data["$og_description"],
      "og_image_url"      => data["$og_image_url"],
      "tracking_campaign" => data["~campaign"] || data["utm_campaign"],
      "tracking_source"   => data["~channel"]  || data["utm_source"],
      "tracking_medium"   => data["~feature"]  || data["utm_medium"],
      "tags"              => Array(data["~tags"]),
      "name"              => data["$link_title"] || data["$marketing_title"] || data["$og_title"] || data["~feature"],
      "provider"          => Grovs::Migrations::PROVIDER_BRANCH,
      "custom_data"       => custom_data
    }
  rescue JSON::ParserError => e
    Rails.logger.warn(message: "branch_migration_client_parse_error", source_id: @source.id, error: e.message)
    { "provider" => Grovs::Migrations::PROVIDER_BRANCH, "custom_data" => {} }
  end
end
