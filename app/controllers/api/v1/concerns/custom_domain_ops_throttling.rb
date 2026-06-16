module Api::V1::Concerns
  # Per-project (not per-IP like Rack::Attack) so the limit holds across IPs.
  # Fails open on Redis errors so a degraded Redis doesn't lock admins out.
  module CustomDomainOpsThrottling
    extend ActiveSupport::Concern

    CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE = 10
    # Preflight DNS lookups can pin a Puma thread for ~6s on timeout.
    CUSTOM_DOMAIN_READS_RATE_LIMIT_PER_MINUTE = 60

    private

    def throttle_custom_domain_ops!
      return if custom_domain_ops_rate_ok?
      response.headers["Retry-After"] = "60"
      render json: { error: "Too many custom-domain changes for this project — try again in a minute" },
             status: :too_many_requests
    end

    def throttle_custom_domain_reads!
      return if custom_domain_reads_rate_ok?
      response.headers["Retry-After"] = "60"
      render json: { error: "Too many custom-domain checks for this project — try again in a minute" },
             status: :too_many_requests
    end

    def custom_domain_ops_rate_ok?
      bucket = Time.current.to_i / 60
      key = "custom_domain_ops:rate:#{@project.id}:#{bucket}"
      count = REDIS.with do |c|
        c.multi do |pipe|
          pipe.incr(key)
          pipe.expire(key, 65)
        end
      end.first
      count <= CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    rescue Redis::BaseError, StandardError => e
      Rails.logger.warn(message: "custom_domain_ops_rate_limit_check_failed",
                        project_id: @project&.id, error: e.message)
      true
    end

    def custom_domain_reads_rate_ok?
      bucket = Time.current.to_i / 60
      key = "custom_domain_reads:rate:#{@project.id}:#{bucket}"
      count = REDIS.with do |c|
        c.multi do |pipe|
          pipe.incr(key)
          pipe.expire(key, 65)
        end
      end.first
      count <= CUSTOM_DOMAIN_READS_RATE_LIMIT_PER_MINUTE
    rescue Redis::BaseError, StandardError => e
      Rails.logger.warn(message: "custom_domain_reads_rate_limit_check_failed",
                        project_id: @project&.id, error: e.message)
      true
    end
  end
end
