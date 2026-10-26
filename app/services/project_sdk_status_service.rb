# frozen_string_literal: true

module ProjectSdkStatusService
  def self.call(project)
    {
      ios_seen_at: mobile_seen_at(project.id, Grovs::Platforms::IOS)&.iso8601,
      android_seen_at: mobile_seen_at(project.id, Grovs::Platforms::ANDROID)&.iso8601,
      web_seen_at: Project.where(id: project.id).pick(:web_sdk_last_seen_at)&.iso8601,
      has_events: events?(project.id),
      has_purchases: purchases?(project.id),
      has_links: Link.joins(:domain).where(domains: { project_id: project.id }).exists?
    }
  end

  MOBILE_LOOKBACK = 30.days

  # Device stamps outlive visitor creation; web_visitor = link redirect, not the SDK.
  # Newest-first so the (project_id, last_seen_at) index can stop at the first match.
  def self.mobile_seen_at(project_id, platform)
    sdk_visitor = Visitor.where(web_visitor: false)
                         .where("visitors.project_id = device_last_seens.project_id")
                         .where("visitors.device_id = device_last_seens.device_id")
    DeviceLastSeen.joins(:device)
                  .where(project_id: project_id, devices: { platform: platform }, last_seen_at: MOBILE_LOOKBACK.ago..)
                  .where(sdk_visitor.arel.exists)
                  .order(last_seen_at: :desc)
                  .pick(:last_seen_at)
  end
  private_class_method :mobile_seen_at

  # Revenue rollups cover projects whose raw purchase rows were never kept.
  def self.purchases?(project_id)
    PurchaseEvent.where(project_id: project_id).exists? ||
      DailyProjectMetric.where(project_id: project_id).where("revenue > 0 OR units_sold > 0").exists?
  end
  private_class_method :purchases?

  # CH-primary leaves PG events empty, so fall through to the ClickHouse events table.
  def self.events?(project_id)
    return true if Event.where(project_id: project_id).exists?
    return false unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: 'SELECT 1 FROM events WHERE project_id = {project_id:UInt64} LIMIT 1',
      placeholders: { project_id: Integer(project_id) }
    )
    Clickhouse.with { |conn| conn.select_all(query) }.to_a.any?
  # Unknown counts as events so a ClickHouse outage does not show the setup panel.
  rescue StandardError => e
    Rails.logger.warn("[ProjectSdkStatusService] events check failed: #{e.class}: #{e.message}")
    true
  end
  private_class_method :events?
end
