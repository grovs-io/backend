# frozen_string_literal: true

# PREREQUISITE, not enforced by code: backfill_snapshots must run first — unbackfilled reads as zeros.
module RevenueLedger
  # A ledger read failed with the PG stat tables cold — falling back would serve their zeros.
  class Unavailable < StandardError; end

  # Short enough that recovery is never masked behind the full dashboard TTL.
  DEGRADED_CACHE_TTL = 30.seconds

  # Under CH-primary the derived stat tables go cold, so revenue must come from the ledger.
  def self.reads_enabled?
    Clickhouse.primary? || Rails.application.config.revenue_reads_from_ledger
  end

  # Under primary a degraded answer is never valid: a silent source swap reads as a parity bug.
  def self.stat_fallback_allowed?
    !Clickhouse.primary? && Grovs.pg_shadow_writes?
  end
end

Rails.application.config.revenue_reads_from_ledger =
  ActiveModel::Type::Boolean.new.cast(ENV.fetch("REVENUE_READS_FROM_LEDGER", false))
