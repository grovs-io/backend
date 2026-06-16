class CloudflareCustomHostnameService
  BASE = "https://api.cloudflare.com/client/v4".freeze
  # CF error codes meaning the custom hostname no longer exists.
  ALREADY_GONE_CODES = [1436, 1437].freeze
  # Status/delete run inside Sidekiq row locks; an unbounded hang would hold DB locks.
  REQUEST_TIMEOUT = 15

  class << self
    # ssl_method "txt" (DNS-01) lets CF issue SSL before the customer flips the CNAME, so
    # the migration cutover can be zero-downtime. "http" (HTTP-01) requires the CNAME first.
    def create(hostname:, ssl_method: "txt")
      resp = HTTParty.post(
        "#{BASE}/zones/#{zone_id}/custom_hostnames",
        headers: auth_headers,
        body: { hostname: hostname, ssl: { method: ssl_method, type: "dv" } }.to_json,
        timeout: REQUEST_TIMEOUT
      )
      parse(resp)
    rescue StandardError => e
      log(e, "create")
      { success: false, error: e.message }
    end

    def status(cf_id:)
      resp = HTTParty.get("#{BASE}/zones/#{zone_id}/custom_hostnames/#{cf_id}", headers: auth_headers, timeout: REQUEST_TIMEOUT)
      parse(resp)
    rescue StandardError => e
      log(e, "status")
      { success: false, error: e.message }
    end

    # Returns true when the hostname is gone at CF (deleted now or already absent); false on
    # a real failure so the caller can retry.
    def delete(cf_id:)
      return true if cf_id.blank?

      resp = HTTParty.delete("#{BASE}/zones/#{zone_id}/custom_hostnames/#{cf_id}", headers: auth_headers, timeout: REQUEST_TIMEOUT)
      body = resp.parsed_response.is_a?(Hash) ? resp.parsed_response : {}
      # CF can return HTTP 200 with body {"success": false}; require both.
      return true if resp.success? && body["success"] != false

      codes = Array(body["errors"]).map { |e| e.is_a?(Hash) ? e["code"] : e }
      (codes & ALREADY_GONE_CODES).any?
    rescue StandardError => e
      log(e, "delete")
      false
    end

    # Adopts a CF hostname left behind by a crashed create(): re-creating returns an error,
    # so the caller looks it up and adopts its id. success is true only when an id is found.
    def lookup(hostname:)
      resp = HTTParty.get(
        "#{BASE}/zones/#{zone_id}/custom_hostnames",
        headers: auth_headers,
        query: { hostname: hostname },
        timeout: REQUEST_TIMEOUT
      )
      body = resp.parsed_response.is_a?(Hash) ? resp.parsed_response : {}
      result = Array(body["result"]).first || {}
      ssl = result["ssl"] || {}
      {
        success: resp.success? && body["success"] != false && result["id"].present?,
        cf_id: result["id"],
        status: result["status"],
        ssl_status: ssl["status"]
      }
    rescue StandardError => e
      log(e, "lookup")
      { success: false }
    end

    def cname_target
      ENV.fetch("CLOUDFLARE_SAAS_CNAME_TARGET", "proxy.sqd.link")
    end

    private

    def zone_id
      ENV.fetch("CLOUDFLARE_ZONE_ID")
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{ENV.fetch('CLOUDFLARE_API_TOKEN')}",
        "Content-Type" => "application/json"
      }
    end

    def log(error, operation)
      Rails.logger.error("[Cloudflare] #{operation} failed: #{error.class} #{error.message}")
    end

    def parse(resp)
      body = resp.parsed_response.is_a?(Hash) ? resp.parsed_response : {}
      result = body["result"] || {}
      ssl = result["ssl"] || {}
      errors = Array(result["verification_errors"]) +
               Array(ssl["validation_errors"]).map { |e| e["message"] } +
               Array(body["errors"]).map { |e| e.is_a?(Hash) ? e["message"] : e }
      # CF can return MULTIPLE validation records simultaneously:
      #   1. Multi-CA dual issuance — one ACME challenge per cert authority. Both must
      #      resolve at DNS for both certs to issue. Both arrive with status "pending".
      #   2. DCV rotation — a stale "valid" record (the prior challenge, still satisfied
      #      in DNS) plus a new "pending" record. We don't want to surface the "valid"
      #      one — the customer already added it and the FE listing it as "to do" is
      #      misleading.
      # Filter: keep every record with a name, drop status "valid" (already satisfied),
      # accept "pending" + any unknown status (future-proofing — surfacing an unknown
      # status is better than hiding a record the customer might need to act on).
      raw_records = Array(ssl["validation_records"]).select { |r| r.is_a?(Hash) && r["txt_name"].present? }
      txt_records = raw_records.reject { |r| r["status"] == "valid" }
                               .map { |r| { "name" => r["txt_name"], "value" => r["txt_value"] } }
      # Hostname Pre-Validation TXT (zone-level setting). CF emits this at
      # `result.ownership_verification` separately from the SSL TXT. When pre-validation
      # is enabled on the zone, CF refuses to issue the cert until both records resolve,
      # so we have to surface it or the customer waits forever for SSL with only the
      # _acme-challenge TXT in place. Type check guards future expansion: CF could in
      # principle add non-TXT verification methods (email, file) carrying the same shape
      # but unsuitable for dashboard TXT-record rendering.
      ov = result["ownership_verification"].is_a?(Hash) ? result["ownership_verification"] : {}
      ov_txt = ov["type"] == "txt"
      {
        # CF returns HTTP 200 with body {"success": false} on logical errors.
        success: resp.success? && body["success"] != false,
        cf_id: result["id"],
        status: result["status"],
        ssl_status: ssl["status"],
        ssl_method: ssl["method"],
        txt_records: txt_records,
        ov_txt_name: ov_txt ? ov["name"] : nil,
        ov_txt_value: ov_txt ? ov["value"] : nil,
        verification_errors: errors.compact.join("; ").presence
      }
    end
  end
end
