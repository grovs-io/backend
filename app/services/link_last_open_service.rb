# frozen_string_literal: true

# Latest app open of a link: the newer of the last-visit row (any link event) and the open events.
module LinkLastOpenService
  OPEN_EVENTS = [Grovs::Events::OPEN, Grovs::Events::INSTALL, Grovs::Events::REINSTALL,
                 Grovs::Events::REACTIVATION].freeze

  def self.call(link)
    device_id, opened_at = [from_last_visits(link), from_events(link) || from_clickhouse(link)]
                           .compact.max_by(&:last)
    return nil unless opened_at

    device = Device.redis_find_by(:id, device_id)
    { opened_at: opened_at.iso8601, platform: device&.platform, model: device&.model,
      app_version: device&.app_version }
  end

  # Link-redirect visitors are web_visitor; only an SDK device means the app opened.
  def self.from_last_visits(link)
    VisitorLastVisit.joins(:visitor)
                    .where(link_id: link.id, visitors: { web_visitor: false })
                    .order(updated_at: :desc)
                    .pick("visitors.device_id", "visitor_last_visits.updated_at")
  end
  private_class_method :from_last_visits

  def self.from_events(link)
    Event.where(link_id: link.id, event: OPEN_EVENTS).order(created_at: :desc).pick(:device_id, :created_at)
  end
  private_class_method :from_events

  # CH-primary leaves PG events empty.
  def self.from_clickhouse(link)
    return nil unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT device_id, created_at FROM events
        WHERE project_id = {project_id:UInt64} AND link_id = {link_id:UInt64}
          AND created_at >= {since:DateTime64(3, 'UTC')}
          AND event_type IN {types:Array(String)}
        ORDER BY created_at DESC LIMIT 1
      SQL
      placeholders: { project_id: Integer(link.domain.project_id), link_id: Integer(link.id), types: OPEN_EVENTS,
                      since: link.created_at.utc.strftime("%Y-%m-%d %H:%M:%S.%L") }
    )
    row = Clickhouse.with { |conn| conn.select_all(query) }.to_a.first
    row && [row["device_id"], Time.zone.parse(row["created_at"].to_s)]
  rescue StandardError => e
    Rails.logger.warn("[LinkLastOpenService] clickhouse lookup failed: #{e.class}: #{e.message}")
    nil
  end
  private_class_method :from_clickhouse
end
