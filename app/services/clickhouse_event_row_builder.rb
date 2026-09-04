# frozen_string_literal: true

# The single definition of a ClickHouse `events` row; caches are per-instance, so reuse one per batch.
class ClickhouseEventRowBuilder
  def build_rows(pg_rows, devices, visitors_index, links)
    pg_rows.filter_map do |pg_row|
      device = devices[pg_row[:device_id]]
      next unless device

      visitor = visitors_index[[pg_row[:project_id], device.id]]
      link = pg_row[:link_id] ? links[pg_row[:link_id]] : nil

      build_row(pg_row, device, visitor, link)
    end
  end

  def build_row(pg_row, device, visitor, link)
    browser = browser_for(device)
    geo = geo_lookup(device.remote_ip)
    src = resolve_ch_source(pg_row, device, link)
    props = ensure_hash(pg_row[:data])

    {
      event_id: src[:event_id],
      project_id: pg_row[:project_id],
      event_type: pg_row[:event],
      device_id: device.id,
      visitor_id: visitor&.id || 0,
      link_id: src[:link_id],
      inviter_id: visitor&.inviter_id || 0,
      campaign_id: src[:campaign_id],
      platform: pg_row[:platform].to_s,
      app_version: pg_row[:app_version].to_s,
      build: pg_row[:build].to_s,
      vendor_id: pg_row[:vendor_id].to_s,
      device_model: device.model.to_s,
      os: browser.platform.name.to_s,
      os_version: browser.platform.version.to_s,
      timezone: device.timezone.to_s,
      language: device.language.to_s,
      country: geo[:country],
      city: geo[:city],
      tracking_source: link&.tracking_source.to_s,
      tracking_medium: link&.tracking_medium.to_s,
      tracking_campaign: link&.tracking_campaign.to_s,
      ads_platform: link&.ads_platform.to_s,
      link_tags: Array(link&.tags),
      sdk_identifier: visitor&.sdk_identifier.to_s,
      sdk_attributes: cap_property_keys(ensure_hash(visitor&.sdk_attributes)),
      engagement_time: Event.clamp_engagement_time(pg_row[:engagement_time]).to_i,
      properties: cap_property_keys(props),
      event_name: pg_row[:event_name].to_s,
      screen_name: resolve_screen_name(pg_row, visitor, props: props),
      session_id: pg_row[:session_id].to_s,
      sdk_generated: src[:sdk_generated],
      link_visitor_id: src[:link_visitor_id],
      tags: Array(pg_row[:tags]),
      ip: pg_row[:ip].to_s,
      remote_ip: pg_row[:remote_ip].to_s,
      path: pg_row[:path].to_s,
      created_at: pg_row[:created_at]
    }
  end

  # PG JSONB reaches us as a Hash or a raw JSON string; CH JSON columns require a Hash.
  def ensure_hash(value)
    case value
    when Hash then value
    when String
      parsed = JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : {}
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Bounds blast radius on CH's max_dynamic_paths; sorted so an over-wide event keeps a stable subset.
  def cap_property_keys(hash)
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    return hash if hash.size <= max

    hash.sort_by { |k, _| k.to_s }.first(max).to_h
  end

  def geo_lookup(ip)
    @geo_cache ||= {}
    @geo_cache[ip] ||= GeoipService.lookup(ip)
  end

  def resolve_screen_name(pg_row, visitor = nil, props: nil)
    screen = screen_name_in(props || ensure_hash(pg_row[:data])) ||
             screen_name_in(ensure_hash(visitor&.sdk_attributes))
    return alias_for(pg_row[:project_id], screen) || screen if screen

    event_name = pg_row[:event_name].to_s
    if event_name.present?
      aliased = alias_for(pg_row[:project_id], event_name)
      return aliased if aliased
    end

    event_type = pg_row[:event].to_s
    return event_name if event_name.present? && [Grovs::Events::SCREEN_VIEW, Grovs::Events::CUSTOM].include?(event_type)

    ''
  end

  private

  # Strip matches stored alias identifiers; 255 cap matches other sources (bloom-indexed column).
  def screen_name_in(hash)
    screen = hash['screen_name'] || hash[:screen_name]
    return nil unless screen.is_a?(String) || screen.is_a?(Symbol) || screen.is_a?(Numeric)

    screen.to_s.strip.presence&.truncate(255, omission: '')
  end

  def alias_for(project_id, key)
    screen_aliases_for_project(project_id)[key].presence
  end

  def browser_for(device)
    @browser_cache ||= {}
    @browser_cache[device.id] ||= Browser.new(device.user_agent.to_s)
  end

  # No .limit: one row per distinct screen_identifier, so the count is bounded per project.
  def screen_aliases_for_project(project_id)
    @screen_alias_cache ||= {}
    @screen_alias_cache[project_id] ||= ScreenAlias
      .where(project_id: project_id)
      .pluck(:screen_identifier, :alias_name)
      .to_h
  end

  # `key?`, not truthiness: it distinguishes "frozen as nil" (organic) from "never frozen".
  def resolve_ch_source(pg_row, device, link)
    ch = pg_row[:ch_meta] || {}
    sdk_generated = ch.key?(:sdk_generated) ? ch[:sdk_generated] : link&.sdk_generated
    {
      event_id: ch[:event_id] || ClickhouseWriteService.generate_event_id(
        project_id: pg_row[:project_id],
        device_id: device.id,
        event_type: pg_row[:event],
        created_at: pg_row[:created_at],
        event_name: pg_row[:event_name].to_s,
        session_id: pg_row[:session_id].to_s,
        link_id: pg_row[:link_id] || 0,
        engagement_time: Event.clamp_engagement_time(pg_row[:engagement_time]).to_i,
        properties: pg_row[:data]
      ),
      link_id: (ch.key?(:link_id) ? ch[:link_id] : pg_row[:link_id]) || 0,
      campaign_id: (ch.key?(:campaign_id) ? ch[:campaign_id] : link&.campaign_id) || 0,
      sdk_generated: sdk_generated ? 1 : 0,
      link_visitor_id: (ch.key?(:link_visitor_id) ? ch[:link_visitor_id] : link&.visitor_id) || 0
    }
  end
end
