require "net/http"
require "resolv"
require "ipaddr"

# Proves a hostname reaches THIS deployment over TLS, from the Rails workload's network position.
class SelfHostedDomainVerificationService
  Result = Struct.new(:active, :error, keyword_init: true)

  PATH = "/.well-known/grovs-domain-verification".freeze
  TIMEOUT_SECONDS = 3
  MAX_BODY_BYTES = 8 * 1024

  class << self
    def verify(hostname, source: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = probe(hostname.to_s.strip.downcase)
      log_probe(hostname, result, source, started)
      result
    end

    def expected_token(hostname)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, hostname.to_s.downcase)
    end

    private

    def probe(hostname)
      address = vetted_address(hostname)
      return failure("This host resolves to a private address") unless address

      status, body = fetch(hostname, address)
      return failure("Host returned HTTP #{status}") unless [200, 404].include?(status)
      return served_elsewhere unless status == 200

      token_matches?(body, hostname) ? Result.new(active: true) : served_elsewhere
    rescue OpenSSL::SSL::SSLError
      failure("No valid certificate for this host yet")
    rescue Timeout::Error
      failure("Host did not respond within #{TIMEOUT_SECONDS}s")
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      failure("Connection refused or reset")
    rescue SocketError, Resolv::ResolvError, IOError => e
      failure("Could not reach this host: #{e.class}")
    rescue StandardError => e
      failure("Verification failed: #{e.class}")
    end

    def log_probe(hostname, result, source, started)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info(message: "custom_domain_probe", hostname: hostname, source: source,
                        active: result.active == true, error: result.error, duration_ms: duration_ms)
    end

    def served_elsewhere
      failure("This host is served by a different deployment")
    end

    def failure(message)
      Result.new(active: false, error: message)
    end

    def token_matches?(body, hostname)
      token = JSON.parse(body.to_s)["token"].to_s
      return false if token.blank?

      ActiveSupport::SecurityUtils.secure_compare(token, expected_token(hostname))
    rescue JSON::ParserError
      false
    end

    # Returned so the hostname is never re-resolved after screening (rebinding).
    def vetted_address(hostname)
      addresses = resolve_addresses(hostname)
      return nil if addresses.blank? || addresses.any? { |a| private_address?(a) }

      addresses.first
    end

    def private_address?(address)
      ip = IPAddr.new(address.to_s)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      return true if ip.to_i.zero? # 0.0.0.0 / :: reach loopback on Linux
      ip.loopback? || ip.private? || ip.link_local? ||
        (ip.ipv4? && ip.to_i >= IPAddr.new("100.64.0.0").to_i && ip.to_i <= IPAddr.new("100.127.255.255").to_i) ||
        (ip.ipv6? && IPAddr.new("fc00::/7").include?(ip))
    rescue IPAddr::Error
      true
    end

    def resolve_addresses(hostname)
      Resolv.getaddresses(hostname)
    end

    def fetch(hostname, address = nil)
      uri = URI("https://#{hostname}#{PATH}")
      Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: TIMEOUT_SECONDS,
                                     read_timeout: TIMEOUT_SECONDS,
                                     ipaddr: address,
                                     verify_mode: OpenSSL::SSL::VERIFY_PEER) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          return [response.code.to_i, read_capped(response)]
        end
      end
    end

    # Streamed: response.body would buffer an attacker-influenced payload in full.
    def read_capped(response)
      body = +""
      response.read_body do |chunk|
        body << chunk.byteslice(0, MAX_BODY_BYTES - body.bytesize)
        break if body.bytesize >= MAX_BODY_BYTES
      end
      body
    end
  end
end
