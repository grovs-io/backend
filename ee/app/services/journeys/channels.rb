# The writes a batch of moves makes to the channels, inside the moves' own transaction.
class Journeys::Channels
  QUIET_FROM = 9
  QUIET_TO = 21
  DEVICE_COLUMNS = Arel.sql("visitors.id, visitors.device_id, devices.platform, NULLIF(devices.push_token, '') IS NOT NULL, devices.timezone")
  ATTRIBUTE_SQL = <<~SQL.squish.freeze
    UPDATE visitors
    SET sdk_attributes = (CASE WHEN jsonb_typeof(sdk_attributes) = 'object' THEN sdk_attributes ELSE '{}'::jsonb END) || jsonb_build_object(:key, :value),
        updated_at = :now
    WHERE project_id = :project AND (id IN (:ids) OR sdk_identifier IN (:identifiers))
    RETURNING id
  SQL

  attr_reader :told, :changed, :campaigns, :sends

  def initialize(journey, now)
    @journey = journey
    @now = now
    @told = []
    @changed = []
    @campaigns = []
    @sends = {}
  end

  # ops: [[kind, step, row], ...] where kind is :push, :show, :hide or :attribute.
  def apply(ops)
    by_kind = ops.group_by(&:first)
    hide(by_kind[:hide]) if by_kind[:hide]
    show(by_kind[:show]) if by_kind[:show]
    push(by_kind[:push]) if by_kind[:push]
    attribute(by_kind[:attribute]) if by_kind[:attribute]
    self
  end

  # Once committed: devices resync, cached visitors go, and the deliverer hears of new pushes.
  def announce
    InAppStamps.touch_users(@told.uniq) if @told.any?
    Visitor.where(id: @changed.uniq).find_each { |v| (keys = v.cache_keys_to_clear).any? && REDIS.with { |c| c.del(*keys) } } if @changed.any?
    @campaigns.uniq.each { |id| PushCampaignDeliverJob.perform_async(id, 0) }
  end

  private

  def hide(ops)
    ops.group_by { |_, step, _| step["id"] }.each do |step_id, list|
      ids = list.map { |_, _, row| row["visitor_id"] }
      SegmentMembership.where(segment_key: @journey.membership_key(step_id), visitor_id: ids).delete_all
      @told.concat(ids)
    end
  end

  def show(ops)
    rows = ops.map do |_, step, row|
      { visitor_id: row["visitor_id"], segment_key: @journey.membership_key(step["id"]), project_id: @journey.project_id, confirmed_at: @now }
    end
    SegmentMembership.insert_all(rows.sort_by { |r| [r[:visitor_id], r[:segment_key]] }, unique_by: %i[visitor_id segment_key])
    @told.concat(rows.pluck(:visitor_id))
  end

  def push(ops)
    devices = Visitor.joins(:device).where(id: ops.map { |_, _, row| row["visitor_id"] }).pluck(DEVICE_COLUMNS).index_by(&:first)
    ops.group_by { |_, step, _| step }.each do |step, list|
      campaign_id = PushCampaign.decode_id(step["campaign_id"])
      rows = list.filter_map { |_, _, row| delivery(campaign_id, step, row, devices[row["visitor_id"]]) }
      next if rows.empty?

      PushDelivery.insert_all(rows)
      rows.each { |r| @sends[r[:journey_person_id]] = [@sends[r[:journey_person_id]], r[:due_at]].compact.max if r[:status] == "pending" }
      PushCampaign.bump!(campaign_id, targeted: rows.size, no_channel: rows.count { |r| r[:status] == "no_channel" })
      @campaigns << campaign_id if rows.any? { |r| r[:status] == "pending" && r[:due_at] <= @now }
    end
  end

  def delivery(campaign_id, step, row, device)
    return nil if device.nil?

    _, device_id, platform, has_token, timezone = device
    reachable = has_token && PushCampaign::PUSH_PLATFORMS.include?(platform)
    { push_campaign_id: campaign_id, visitor_id: row["visitor_id"], device_id: device_id, platform: platform, variant: "a", recipient: "journey",
      due_at: step["quiet_hours"] ? daytime(timezone) : @now, status: reachable ? "pending" : "no_channel", journey_person_id: row["id"],
      created_at: @now, updated_at: @now }
  end

  # Inside 09:00-21:00 on the device's clock, or the next 09:00 there.
  def daytime(timezone)
    local = @now.in_time_zone(ActiveSupport::TimeZone[timezone.to_s] || "UTC")
    return @now if local.hour >= QUIET_FROM && local.hour < QUIET_TO

    morning = local.change(hour: QUIET_FROM)
    local.hour >= QUIET_TO ? morning + 1.day : morning
  end

  # A person with an identifier gets the attribute on every device they use.
  def attribute(ops)
    ops = ops.reverse.uniq { |_, step, row| [row["id"], step["key"]] }.reverse
    ops.group_by { |_, step, _| [step["key"], step["value"]] }.each do |(key, value), list|
      ids = list.map { |_, _, row| row["visitor_id"] }
      identifiers = list.filter_map { |_, _, row| row["person_key"].delete_prefix("i:") if row["person_key"].start_with?("i:") }
      sql = Visitor.sanitize_sql([ATTRIBUTE_SQL, { key: key, value: value, now: @now, project: @journey.project_id, ids: ids,
                                                   identifiers: identifiers.presence || [nil] }])
      @changed.concat(Visitor.connection.exec_query(sql).rows.flatten)
    end
    @told.concat(@changed)
  end
end
