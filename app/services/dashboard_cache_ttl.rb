# frozen_string_literal: true

# Single source of truth for the dashboard read-cache freshness SLA.
# Env-tunable so staging (fast-lane rollup rebuilds) can shrink it; the default
# keeps the ~15-min legacy staleness bound. Unparseable values fall back to the
# default instead of breaking every dashboard request.
module DashboardCacheTtl
  DEFAULT_SECONDS = 300

  def self.value
    Integer(ENV.fetch("DASHBOARD_CACHE_TTL_SECONDS", DEFAULT_SECONDS)).seconds
  rescue ArgumentError
    DEFAULT_SECONDS.seconds
  end
end
