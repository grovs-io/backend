# frozen_string_literal: true

# Mirrors link filter attributes into ClickHouse: docs/plans/2026-08-01-link-dimensions.md
class LinkDimensionSyncService
  # Bounds a hung ClickHouse so a link create/update cannot hang on the request thread.
  SYNC_TIMEOUT_SECONDS = 2

  class << self
    def sync(link)
      return unless Clickhouse.enabled?

      write([row_for(link)], settings: Clickhouse::ASYNC_INSERT)
    rescue StandardError => e
      log_failure(:sync, link, e)
    end

    def tombstone(link)
      return unless Clickhouse.enabled?

      write([row_for(link, deleted: 1, version: Time.current)], settings: Clickhouse::ASYNC_INSERT)
    rescue StandardError => e
      log_failure(:tombstone, link, e)
    end

    # Bulk fire-and-forget, for request-path callers that must not fail on a ClickHouse outage.
    def sync_many(links)
      return unless Clickhouse.enabled?

      sync_all(links)
    rescue StandardError => e
      log_failure(:sync_many, nil, e)
    end

    # Raises, unlike sync_many: backfill and reconciliation callers must see a failed write.
    def sync_all(links, version: nil)
      rows = links.filter_map { |link| row_for(link, version: version) }
      write(rows)
      rows.size
    end

    # A dropped tombstone has no Postgres row left to re-read, so ids come from the caller.
    def tombstone_missing(project_id, link_ids)
      rows = link_ids.map do |id|
        { project_id: project_id, link_id: id, deleted: 1, version: ch_time(Time.current) }
      end
      write(rows)
      rows.size
    end

    # version from the SOURCE row: a late stale object carries its older updated_at and loses.
    def row_for(link, deleted: 0, version: nil)
      project_id = link.domain&.project_id
      return nil if project_id.nil?

      {
        project_id: project_id,
        link_id: link.id,
        active: link.active ? 1 : 0,
        sdk_generated: link.sdk_generated ? 1 : 0,
        campaign_id: link.campaign_id.to_i,
        ads_platform: link.ads_platform.to_s,
        name: link.name.to_s,
        title: link.title.to_s,
        subtitle: link.subtitle.to_s,
        path: link.path.to_s,
        tags: Array(link.tags).map(&:to_s),
        deleted: deleted,
        version: ch_time(version || link.updated_at || Time.current)
      }
    end

    private

    # Microseconds: a create then immediate hidden-toggle shares a millisecond, and ties are arbitrary.
    def ch_time(time) = time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")

    def write(rows, settings: {})
      rows = rows.compact
      return if rows.empty?

      Clickhouse.with_request_timeout(SYNC_TIMEOUT_SECONDS) do
        Clickhouse.with { |conn| conn.insert("link_dimensions", rows, settings: settings) }
      end
    end

    def log_failure(operation, link, error)
      Grovs::Metrics.increment("clickhouse.link_dimension.sync_failed", tags: { op: operation })
      Rails.logger.error("LinkDimensionSyncService##{operation} link=#{link&.id}: #{error.class}: #{error.message}")
      nil
    end
  end
end
