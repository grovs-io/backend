# Uniform return type from every provider client.
# outcome ∈ [:found, :not_found, :transient_error]
class MigrationLookupResult
  RETRY_AFTER_MIN_SECONDS = 5
  RETRY_AFTER_MAX_SECONDS = 3600

  attr_reader :outcome, :http_status, :retry_after, :payload

  def initialize(outcome:, http_status: nil, retry_after: nil, payload: nil)
    @outcome     = outcome
    @http_status = http_status
    @retry_after = retry_after
    @payload     = payload
  end

  def self.found(payload, http_status: 200)
    new(outcome: :found, http_status: http_status, payload: payload)
  end

  def self.not_found(http_status: 404)
    new(outcome: :not_found, http_status: http_status)
  end

  def self.transient_error(http_status:, retry_after: nil)
    new(outcome: :transient_error, http_status: http_status,
        retry_after: parse_retry_after(retry_after))
  end

  # Probe verdicts (sentinel-slug lookup → credentials health). Shared by the
  # onboarding create probe and the standalone test endpoint.
  PROBE_OK             = "credentials_ok".freeze
  PROBE_UNEXPECTED     = "unexpected_success".freeze
  PROBE_INVALID        = "credentials_invalid".freeze
  PROBE_RATE_LIMITED   = "upstream_rate_limited".freeze
  PROBE_UNREACHABLE    = "upstream_unreachable".freeze

  # not_found = creds work (the sentinel slug is legitimately absent upstream).
  # found     = the sentinel unexpectedly resolved — investigate, but creds are valid.
  # 400/401/403 = credentials_invalid: AppsFlyer returns 400 for a bad onelink_id and
  # 401 for a bad/under-entitled token (e.g. no OneLink API access); Branch 401/403 = bad key.
  def probe_outcome
    case outcome
    when :not_found then PROBE_OK
    when :found     then PROBE_UNEXPECTED
    when :transient_error
      case http_status
      when 400, 401, 403 then PROBE_INVALID
      when 429           then PROBE_RATE_LIMITED
      else                    PROBE_UNREACHABLE
      end
    end
  end

  # Defensive parser. Returns nil for nil/blank/garbage/zero/negative (which would
  # otherwise cause an immediate-retry loop). Integer + HTTP-date both clamped to [MIN, MAX].
  def self.parse_retry_after(value)
    return nil if value.nil? || value.to_s.strip.empty?
    seconds = if value.is_a?(Integer)
                value
              elsif value.to_s.match?(/\A-?\d+\z/)
                Integer(value.to_s)
              else
                begin
                  (Time.httpdate(value.to_s) - Time.current).to_i
                rescue ArgumentError
                  nil
                end
              end
    return nil if seconds.nil? || seconds <= 0
    seconds.clamp(RETRY_AFTER_MIN_SECONDS, RETRY_AFTER_MAX_SECONDS)
  end
end
