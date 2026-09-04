# frozen_string_literal: true

# Generates realistic event data for frontend testing.
#
# Usage:
#   bundle exec rake seed_events:generate INSTANCE_ID=<id> [DAYS=30] [DEVICES=100] [EVENTS=5000]
#
# Creates campaigns, links, devices, visitors, and events on the production
# project. Events go to both PG and ClickHouse (if enabled). Each device gets
# a realistic user journey with proper sessions, screen flows, and custom events.

namespace :seed_events do
  desc "Generate realistic test events for an instance's production project"
  task generate: :environment do
    # Suppress SQL logging — otherwise 500k INSERTs produce gigabytes of output
    ActiveRecord::Base.logger.level = :warn

    instance_id = ENV.fetch("INSTANCE_ID") { abort "Usage: rake seed_events:generate INSTANCE_ID=<id>" }

    # Wipes the production project before seeding; echo the id to prevent a wrong-tenant run.
    unless ENV["CONFIRM"] == instance_id
      abort "Refusing to wipe+seed instance #{instance_id}: re-run with CONFIRM=#{instance_id} to proceed."
    end
    days        = (ENV["DAYS"] || 90).to_i
    num_devices = (ENV["DEVICES"] || 100).to_i
    num_events  = (ENV["EVENTS"] || 5000).to_i
    skip_pg_stats = ENV["SKIP_PG_STATS"] == "true" || num_events > 50_000

    instance = Instance.find_by(id: instance_id)
    abort "Instance not found for ID: #{instance_id}" unless instance

    project = instance.production
    abort "No production project for instance #{instance_id}" unless project

    domain = project.domain
    abort "No domain for production project" unless domain

    redirect_config = project.redirect_config
    redirect_config ||= RedirectConfig.create!(project: project)

    ch_enabled = Clickhouse.enabled? || Clickhouse.read_enabled?

    puts "=== Seed Events Generator ==="
    puts "Instance:    #{instance.id}"
    puts "Project:     #{project.id} (#{project.name})"
    puts "Domain:      #{domain.full_domain}"
    puts "Devices:     #{num_devices}"
    puts "Events:      ~#{num_events}"
    puts "Days:        #{days}"
    puts "ClickHouse:  #{ch_enabled ? 'YES' : 'no (skipping CH writes)'}"
    puts "PG stats:    #{skip_pg_stats ? 'SKIP (too many events)' : 'yes'}"
    puts ""

    # --- Clear old seed data for this project ---
    puts "Clearing old data for project #{project.id}..."
    Event.where(project_id: project.id).delete_all
    PurchaseEvent.where(project_id: project.id).delete_all
    # Aggregate/stat tables are upsert-keyed by date, so without wiping them a
    # reseed leaves stale rows on dates the new run doesn't touch — inflating
    # installs/revenue across runs. Clear them for a clean rebuild.
    LinkDailyStatistic.where(project_id: project.id).delete_all
    VisitorDailyStatistic.where(project_id: project.id).delete_all
    DailyProjectMetric.where(project_id: project.id).delete_all
    if ch_enabled
      ch_tables = %w[events session_events session_summary user_profiles visitor_daily
                     link_daily purchase_events project_daily project_country_daily
                     purchase_project_daily purchase_product_daily]
      Clickhouse.with do |conn|
        ch_tables.each do |t|
          conn.execute("ALTER TABLE #{t} DELETE WHERE project_id = #{project.id}")
        end
      end
      # Wait for CH mutations to finish
      sleep 2
      puts "ClickHouse tables cleared for project #{project.id}"
    end
    puts ""

    # --- SDK integrations ---
    setup_sdk_integrations(instance, domain)

    # --- Campaigns ---
    campaigns = CAMPAIGN_CONFIGS.map do |cfg|
      Campaign.find_or_create_by!(project: project, name: cfg[:name])
    end
    puts "Campaigns: #{campaigns.map(&:name).join(', ')}"

    # --- Links (first 11 in campaigns, last 4 standalone for "Links" source) ---
    standalone_count = 4
    links = LINK_CONFIGS.each_with_index.map do |cfg, i|
      campaign = i < LINK_CONFIGS.size - standalone_count ? campaigns[i % campaigns.size] : nil
      # find_or_initialize + assign so reruns refresh name/title/subtitle on
      # links that already exist (older seed runs / SDK links could lack them).
      link = Link.find_or_initialize_by(domain: domain, path: cfg[:path], active: true)
      link.redirect_config ||= redirect_config
      link.generated_from_platform ||= %w[ios android web].sample
      link.assign_attributes(
        name: cfg[:name], title: cfg[:title], subtitle: cfg[:subtitle],
        data: [cfg[:data]], tags: cfg[:tags], campaign: campaign,
        tracking_source: cfg[:source], tracking_medium: cfg[:medium],
        tracking_campaign: campaign&.name
      )
      link.save!
      link
    end
    campaign_links = links.select { |l| l.campaign_id.present? }
    standalone_links = links.reject { |l| l.campaign_id.present? }
    links_by_id = links.index_by(&:id)
    puts "Links: #{campaign_links.size} in campaigns, #{standalone_links.size} standalone"

    # --- Devices & visitors ---
    devices_and_visitors = []
    platform_counts = Hash.new(0)

    num_devices.times do |i|
      plat = weighted_pick(PLATFORM_WEIGHTS)
      geo = GEO_LOCATIONS.sample
      variant = PLATFORM_DATA[plat][:device_variants].sample
      ua = variant[:ua]
      model = variant[:models].sample
      ver_idx = rand(APP_VERSIONS.size)

      device = Device.create!(
        vendor: "seed-#{SecureRandom.hex(8)}",
        user_agent: ua, ip: geo[:ip], remote_ip: geo[:ip],
        platform: plat, model: model,
        app_version: APP_VERSIONS[ver_idx], build: BUILDS[ver_idx],
        language: geo[:language], timezone: geo[:timezone],
        screen_width: PLATFORM_DATA[plat][:widths].sample,
        screen_height: PLATFORM_DATA[plat][:heights].sample
      )

      visitor = Visitor.create!(
        project: project, device: device,
        web_visitor: plat == "web", uuid: SecureRandom.uuid,
        sdk_identifier: rand < 0.6 ? "user_#{SecureRandom.hex(6)}" : nil,
        sdk_attributes: rand < 0.4 ? random_sdk_attributes : nil
      )

      # Assign each user a primary acquisition source.
      # Distribution: 40% organic, 30% campaigns, 18% links, 12% referrals
      user_source = weighted_pick(USER_SOURCE_WEIGHTS)

      platform_counts[plat] += 1
      devices_and_visitors << {
        device: device, visitor: visitor, platform: plat,
        geo: geo, browser: Browser.new(ua), source: user_source
      }
      print "\rDevices: #{i + 1}/#{num_devices}" if (i + 1) % 50 == 0
    end
    src_summary = devices_and_visitors.group_by { |d| d[:source] }.transform_values(&:size)
    puts "\rDevices: #{num_devices} — #{platform_counts.sort_by { |_, v| -v }.map { |k, v| "#{k}: #{v}" }.join(', ')}"
    puts "Sources: #{src_summary.sort_by { |_, v| -v }.map { |k, v| "#{k}: #{v}" }.join(', ')}"

    # --- SDK-generated referral links (created by visitors who share) ---
    referral_sharers = devices_and_visitors.select { |dv| dv[:visitor].sdk_identifier.present? }.sample([num_devices / 10, 3].max)
    referral_links = referral_sharers.map.with_index do |dv, _i|
      link = Link.find_or_initialize_by(domain: domain, path: "referral-#{dv[:visitor].id}", active: true)
      link.redirect_config ||= redirect_config
      link.assign_attributes(
        name: "Referral by #{dv[:visitor].sdk_identifier}",
        title: "Join via #{dv[:visitor].sdk_identifier}",
        sdk_generated: true, visitor_id: dv[:visitor].id,
        generated_from_platform: dv[:platform],
        data: [{ "referrer" => dv[:visitor].sdk_identifier }],
        tags: ["referral", "sdk"]
      )
      link.save!
      link
    end
    referral_links.each { |l| links_by_id[l.id] = l }
    puts "Referral links: #{referral_links.size} (SDK-generated)"

    # --- Generate events ---
    now = Time.current
    start_time = now - days.days
    pg_batch = []
    ch_batch = []
    purchases = []
    events_created = 0
    events_per_device = num_events / num_devices
    remainder = num_events % num_devices

    devices_and_visitors.each_with_index do |dv, idx|
      device = dv[:device]
      visitor = dv[:visitor]
      platform = dv[:platform]
      geo = dv[:geo]
      browser = dv[:browser]
      user_source = dv[:source]
      target = events_per_device + (idx < remainder ? 1 : 0)
      # Install day: spread across the whole window (minus a 1-day tail so the
      # first session never lands in the future). Every date range — including
      # recent ones — then shows fresh installs, and since each device's channel
      # (organic/campaign/link/referral) is independent of install time, all
      # channels appear in every range. Recent installs naturally retain less.
      install_time = start_time + rand((days - 1).clamp(1, days).days).seconds
      available_window = (now - install_time).to_i
      dv[:install_time] = install_time
      device_events = []

      # --- Install: always through the user's primary source ---
      install_link = link_for_source(user_source, campaign_links, standalone_links, referral_links)
      device_events << make_event("install", project, device, visitor, install_link, install_time, platform, geo, browser, links_by_id)

      # USER_REFERRED — if installed via a referral link (sdk_generated with a visitor_id)
      if install_link&.sdk_generated && install_link.visitor_id.present?
        device_events << make_event("user_referred", project, device, visitor, install_link, install_time + 1.second, platform, geo, browser, links_by_id)
      end

      # --- Retention persona: determines how many days AND how far this user comes back ---
      persona = weighted_pick(RETENTION_PERSONA_WEIGHTS)
      first_day_screens = RETENTION_PERSONAS[persona][:first_day_screens]
      return_probability = RETENTION_PERSONAS[persona][:return_probability]
      max_active_days = RETENTION_PERSONAS[persona][:max_active_days]

      # --- First session: always on install day (install-day anchor) ---
      first_session_id = "sess-#{SecureRandom.hex(6)}"
      first_session_start = install_time + rand(60..3600).seconds
      device_events << make_event("app_open", project, device, visitor, install_link, first_session_start, platform, geo, browser, links_by_id, 
session_id: first_session_id)

      first_day_screens.each_with_index do |screen, j|
        t = first_session_start + (j + 1) * rand(5..30).seconds
        device_events << make_event(
          "screen_view", project, device, visitor, install_link, t, platform, geo, browser, links_by_id,
          event_name: "screen_view", session_id: first_session_id,
          engagement_time: rand(800..45_000),
          data: { "screen_name" => screen, "screen_class" => screen.split("_").map(&:capitalize).join }
        )
      end

      # --- Return sessions: constrained by persona's active span ---
      # max_active_days caps HOW FAR from install sessions can be (controls max_event_date).
      # return_probability caps HOW MANY return days within that window.
      # Bouncers: 0 days, 0 sessions. Churners: 1 day, ~1 session. Power: full window, many.
      # +1 day because day 0 is handled by the first session above and skipped in the loop.
      # Bouncer (max_active_days=0) → persona_window=0 → loop never enters.
      # Churner (max_active_days=1) → persona_window=2 days → rand can land on day 1.
      persona_window = if max_active_days&.zero?
                         0
                       elsif max_active_days.nil? || (max_active_days + 1).days.to_i >= available_window
                         available_window
                       else
                         (max_active_days + 1).days.to_i
                       end
      persona_days = [(persona_window / 1.day).to_i, 0].max
      max_return_days = (persona_days * return_probability).ceil
      return_days_used = 0

      while device_events.size < target && return_days_used < max_return_days && persona_window > 0
        session_start = install_time + rand(persona_window).seconds
        days_since_install = ((session_start - install_time) / 1.day).to_i
        next if days_since_install.zero? # first day handled above

        return_days_used += 1

        session_id = "sess-#{SecureRandom.hex(6)}"
        session_link = rand < 0.30 ? link_for_source(user_source, campaign_links, standalone_links, referral_links) : nil

        # App open
        device_events << make_event("app_open", project, device, visitor, session_link, session_start, platform, geo, browser, links_by_id, 
session_id: session_id)

        # Screen flow: 2-8 screens per session
        screen_flow = SCREEN_FLOWS.sample
        screens_to_show = screen_flow.sample(rand(2..[screen_flow.size, 8].min))

        screens_to_show.each_with_index do |screen, j|
          t = session_start + (j + 1) * rand(3..45).seconds
          device_events << make_event(
            "screen_view", project, device, visitor, session_link, t, platform, geo, browser, links_by_id,
            event_name: "screen_view", session_id: session_id,
            engagement_time: rand(800..45_000),
            data: { "screen_name" => screen, "screen_class" => screen.split("_").map(&:capitalize).join }
          )
        end

        # Custom events tied to what they were doing
        rand(0..4).times do
          t = session_start + rand(30..600).seconds
          evt = CUSTOM_EVENTS.sample
          device_events << make_event(
            "custom", project, device, visitor, session_link, t, platform, geo, browser, links_by_id,
            event_name: evt[:name], session_id: session_id,
            engagement_time: rand(200..15_000),
            data: evt[:props_generator].call
          )
        end

        # Purchase event (~12% of sessions)
        if rand < 0.12
          purchase_link = session_link || campaign_links.sample
          t = session_start + rand(60..900).seconds
          product = PRODUCTS.sample
          price_cents = product[:price_cents]
          device_events << make_event(
            "custom", project, device, visitor, purchase_link, t, platform, geo, browser, links_by_id,
            event_name: "purchase", session_id: session_id,
            data: { "product_id" => product[:id], "price" => price_cents / 100.0, "currency" => "USD" }
          )
          purchases << build_purchase(
            project: project, device: device, visitor: visitor, link: purchase_link,
            platform: platform, product: product, time: t,
            event_type: Grovs::Purchases::EVENT_BUY
          )
        end

        # Link view/open — every link-attributed session gets a VIEW, 80% get OPEN
        if session_link
          device_events << make_event("view", project, device, visitor, session_link, session_start - rand(1..30).seconds, platform, geo, browser, links_by_id, 
session_id: session_id)
          if rand < 0.80
            device_events << make_event("open", project, device, visitor, session_link, session_start, platform, geo, browser, links_by_id, 
session_id: session_id)
          end
        end

        # Time spent
        if rand < 0.8
          device_events << make_event(
            "time_spent", project, device, visitor, nil, session_start + rand(30..900).seconds,
            platform, geo, browser, links_by_id,
            session_id: session_id, engagement_time: rand(10_000..300_000)
          )
        end
      end

      # Reinstall (8%)
      if rand < 0.08 && days >= 3
        t = install_time + rand(3..days).days
        device_events << make_event("reinstall", project, device, visitor, links.sample, t, platform, geo, browser, links_by_id) if t < now
      end

      # Reactivation (12%)
      if rand < 0.12 && days >= 5
        t = install_time + rand(5..days).days
        device_events << make_event("reactivation", project, device, visitor, nil, t, platform, geo, browser, links_by_id) if t < now
      end

      # Trim to exact target
      device_events = device_events.first(target) if device_events.size > target

      # Track latest event for user_profiles.last_seen
      dv[:last_event_time] = device_events.map { |e| e[:created_at] }.compact.max || install_time

      # Build rows
      device_events.each do |e|
        pg_batch << build_pg_row(e)
        ch_batch << e[:ch_row] if ch_enabled && e[:ch_row]
      end

      # Flush in batches
      if pg_batch.size >= 5000
        Event.insert_all(pg_batch)
        if ch_enabled && ch_batch.any?
          Clickhouse.with { |conn| conn.insert("events", ch_batch.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
        end
        events_created += pg_batch.size
        print "\rEvents: #{events_created}/#{num_events}"
        pg_batch = []
        ch_batch = []
      end
    end

    # Flush remaining
    if pg_batch.any?
      Event.insert_all(pg_batch)
      if ch_enabled && ch_batch.any?
        Clickhouse.with { |conn| conn.insert("events", ch_batch.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
      end
      events_created += pg_batch.size
    end
    puts "\rEvents: #{events_created} created (PG#{ch_enabled ? ' + ClickHouse' : ''})"

    # --- Follow-up cancellations / refunds (~10% of buys) ---
    # Subscriptions get a CANCEL, one-time purchases get a REFUND, dated a few
    # days after the original buy (but never in the future). Populates the
    # cancellations surface and gives revenue a realistic negative tail.
    buys = purchases.select { |p| p[:event_type] == Grovs::Purchases::EVENT_BUY }
    followups = buys.filter_map do |b|
      next unless rand < 0.10
      ft = b[:purchase_date] + rand(2..[days, 3].max).days
      next if ft >= now
      event_type = b[:purchase_type] == Grovs::Purchases::TYPE_SUBSCRIPTION ? Grovs::Purchases::EVENT_CANCEL : Grovs::Purchases::EVENT_REFUND
      b.merge(
        event_type: event_type,
        transaction_id: "TXN-#{SecureRandom.hex(8)}",
        purchase_date: ft
      )
    end
    purchases.concat(followups)
    puts "Follow-up cancellations/refunds: #{followups.size}"

    # --- Purchase events: PG (source of dashboard revenue) + ClickHouse ---
    if purchases.any?
      purchases.each_slice(5000) do |slice|
        PurchaseEvent.insert_all(slice.map { |p| purchase_pg_row(p) })
      end
      puts "PG purchase_events: #{purchases.size}"

      if ch_enabled
        purchases.each_slice(5000) do |slice|
          Clickhouse.with { |conn| conn.insert("purchase_events", slice.map { |p| ClickhouseWriteService.send(:format_timestamps, purchase_ch_row(p)) }) }
        end
        puts "ClickHouse purchase_events: #{purchases.size}"
      end
    end

    # --- CH user profiles ---
    if ch_enabled
      profile_rows = devices_and_visitors.each_slice(5000).flat_map do |slice|
        slice.map do |dv|
          {
            project_id: project.id, visitor_id: dv[:visitor].id,
            sdk_identifier: dv[:visitor].sdk_identifier.to_s,
            properties: dv[:visitor].sdk_attributes.is_a?(Hash) ? dv[:visitor].sdk_attributes : {},
            first_seen: dv[:install_time] || dv[:visitor].created_at,
            last_seen: dv[:last_event_time] || Time.current,
            country: dv[:geo][:country], platform: dv[:device].platform_for_metrics,
            inviter_id: dv[:visitor].inviter_id || 0
          }
        end
      end
      profile_rows.each_slice(5000) do |slice|
        Clickhouse.with { |conn| conn.insert("user_profiles", slice.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
      end
      puts "ClickHouse user_profiles: #{profile_rows.size}"

      # --- CH visitor_daily (needed for retention analytics) ---
      # Aggregate from the CH events we just inserted — much faster than querying PG row-by-row.
      vd_sql = <<~SQL
        INSERT INTO visitor_daily
        SELECT
          project_id, visitor_id,
          toDate(created_at) AS event_date,
          'OPEN' AS event_type,
          platform,
          count() AS cnt,
          sum(engagement_time) AS total_engagement_time,
          0 AS inviter_id_state
        FROM events
        WHERE project_id = #{project.id}
        GROUP BY project_id, visitor_id, event_date, platform
      SQL
      Clickhouse.with { |conn| conn.execute(vd_sql) }
      vd_count = Clickhouse.with { |conn| conn.select_value("SELECT count() FROM visitor_daily WHERE project_id = #{project.id}") }
      puts "ClickHouse visitor_daily: #{vd_count} (aggregated from events)"
    end

    # --- Build sessions (populates session_events + session_summary) ---
    if ch_enabled
      puts ""
      puts "Building sessions (this may take a while for large datasets)..."
      lookback = [days, 90].max

      # Temporarily enable both flags + expand lookback so SessionBuildJob processes all seed data
      old_write = Rails.application.config.clickhouse_write_enabled
      old_read = Rails.application.config.clickhouse_read_enabled
      Rails.application.config.clickhouse_write_enabled = true
      Rails.application.config.clickhouse_read_enabled = true

      begin
        job = SessionBuildJob.new
        job.defer_open_sessions = false
        job.perform(lookback_days: lookback)
        puts "Sessions built successfully"
      rescue StandardError => e
        puts "Session build warning: #{e.message}"
      ensure
        Rails.application.config.clickhouse_write_enabled = old_write
        Rails.application.config.clickhouse_read_enabled = old_read
      end
    end

    # --- PG daily stats ---
    unless skip_pg_stats
      puts ""
      puts "Backfilling PG daily statistics..."
      backfill_link_daily_stats(project, links, start_time, now)
      backfill_visitor_daily_stats(project, devices_and_visitors, start_time, now)
      backfill_daily_project_metrics(project, start_time, now)
      backfill_link_revenue(project, purchases)
      backfill_project_revenue(project, purchases)
    end

    puts ""
    puts "=== Done ==="
    puts "#{campaigns.size} campaigns, #{links.size} links, #{num_devices} devices, #{events_created} events, #{purchases.size} purchase events"
  end

  # ============================================================
  # Event builders
  # ============================================================

  def make_event(type, project, device, visitor, link, time, platform, geo, browser, links_by_id,
                 event_name: nil, session_id: nil, engagement_time: nil, data: nil)
    actual_type = case type
                  when "screen_view" then Grovs::Events::SCREEN_VIEW
                  when "custom" then Grovs::Events::CUSTOM
                  else type
                  end

    ch_row = {
      event_id: ClickhouseWriteService.generate_event_id(
        project_id: project.id, device_id: device.id, event_type: actual_type,
        created_at: time, event_name: (event_name || "").to_s,
        session_id: (session_id || "").to_s, link_id: link&.id || 0,
        engagement_time: engagement_time.to_i,
        properties: data.is_a?(Hash) ? data : nil
      ),
      project_id: project.id, event_type: actual_type,
      device_id: device.id, visitor_id: visitor.id,
      link_id: link&.id || 0, inviter_id: visitor.inviter_id || 0,
      campaign_id: link&.campaign_id || 0,
      platform: platform, app_version: device.app_version.to_s,
      build: device.build.to_s, vendor_id: device.vendor.to_s,
      device_model: device.model.to_s,
      os: browser.platform.name.to_s, os_version: browser.platform.version.to_s,
      timezone: device.timezone.to_s, language: device.language.to_s,
      country: geo[:country], city: geo[:city],
      tracking_source: link&.tracking_source.to_s,
      tracking_medium: link&.tracking_medium.to_s,
      tracking_campaign: link&.tracking_campaign.to_s,
      ads_platform: link&.ads_platform.to_s,
      link_tags: Array(link&.tags),
      sdk_identifier: visitor.sdk_identifier.to_s,
      sdk_attributes: visitor.sdk_attributes.is_a?(Hash) ? visitor.sdk_attributes : {},
      engagement_time: engagement_time.to_i,
      properties: data.is_a?(Hash) ? data : {},
      event_name: (event_name || "").to_s,
      screen_name: type == "screen_view" && data.is_a?(Hash) ? data["screen_name"].to_s : "",
      session_id: (session_id || "").to_s,
      sdk_generated: link&.sdk_generated ? 1 : 0,
      link_visitor_id: link&.visitor_id || 0,
      tags: Array(link&.tags),
      ip: device.ip.to_s, remote_ip: device.remote_ip.to_s,
      path: link&.path.to_s,
      created_at: time
    }

    {
      event: actual_type, project_id: project.id, device_id: device.id,
      link_id: link&.id, data: data, event_name: event_name || "",
      platform: platform, engagement_time: engagement_time,
      session_id: session_id || "", tags: Array(link&.tags),
      ip: device.ip, remote_ip: device.remote_ip,
      vendor_id: device.vendor, app_version: device.app_version,
      build: device.build, path: link&.path, created_at: time,
      ch_row: ch_row
    }
  end

  def build_pg_row(event)
    {
      project_id: event[:project_id], device_id: event[:device_id], link_id: event[:link_id],
      event: event[:event], event_name: event[:event_name] || "", platform: event[:platform],
      data: event[:data], engagement_time: event[:engagement_time],
      session_id: event[:session_id] || "", tags: event[:tags] || [],
      ip: event[:ip], remote_ip: event[:remote_ip], vendor_id: event[:vendor_id],
      app_version: event[:app_version], build: event[:build], path: event[:path],
      processed: true, created_at: event[:created_at], updated_at: event[:created_at]
    }
  end

  # ============================================================
  # Purchase builders
  # ============================================================

  # Builds a single purchase descriptor. One descriptor fans out to a PG
  # PurchaseEvent row, a ClickHouse purchase_events row, and the revenue
  # aggregates. usd_price_cents is always the positive magnitude — the sign
  # is derived per event_type by signed_revenue_cents.
  def build_purchase(project:, device:, visitor:, link:, platform:, product:, time:, event_type:)
    cents = product[:price_cents]
    {
      project_id: project.id, device_id: device.id, visitor_id: visitor.id,
      link_id: link&.id, platform: platform,
      product_id: product[:id], purchase_type: product[:type],
      currency: "USD", price_cents: cents, usd_price_cents: cents, quantity: 1,
      event_type: event_type,
      store_source: store_source_for(platform),
      transaction_id: "TXN-#{SecureRandom.hex(8)}",
      original_transaction_id: "OTXN-#{SecureRandom.hex(6)}",
      purchase_date: time
    }
  end

  # iOS → App Store, Android → Play. Web/desktop purchases have no store
  # (treated as off-store payments, e.g. Stripe) so store_source is nil.
  def store_source_for(platform)
    case platform
    when Grovs::Platforms::IOS then Grovs::Webhooks::APPLE
    when Grovs::Platforms::ANDROID then Grovs::Webhooks::GOOGLE
    end
  end

  # Signed USD-cent revenue contribution of a purchase descriptor.
  # Mirrors PurchaseEvent#revenue_delta: buys add, refunds subtract,
  # non-subscription cancels subtract, subscription cancels are neutral.
  def signed_revenue_cents(purchase)
    cents = purchase[:usd_price_cents].to_i * purchase[:quantity]
    case purchase[:event_type]
    when Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED then cents
    when Grovs::Purchases::EVENT_REFUND then -cents
    when Grovs::Purchases::EVENT_CANCEL
      purchase[:purchase_type] != Grovs::Purchases::TYPE_SUBSCRIPTION ? -cents : 0
    else 0
    end
  end

  # Mirrors PurchaseEvent#cancellation?.
  def counts_as_cancellation?(purchase)
    purchase[:event_type] == Grovs::Purchases::EVENT_CANCEL ||
      (purchase[:event_type] == Grovs::Purchases::EVENT_REFUND && purchase[:purchase_type] != Grovs::Purchases::TYPE_SUBSCRIPTION)
  end

  def purchase_pg_row(purchase)
    sub = purchase[:purchase_type] == Grovs::Purchases::TYPE_SUBSCRIPTION
    {
      project_id: purchase[:project_id], device_id: purchase[:device_id], link_id: purchase[:link_id],
      product_id: purchase[:product_id], purchase_type: purchase[:purchase_type],
      currency: purchase[:currency], price_cents: purchase[:price_cents], usd_price_cents: purchase[:usd_price_cents],
      quantity: purchase[:quantity], event_type: purchase[:event_type],
      store_source: purchase[:store_source], store: purchase[:store_source].present?,
      webhook_validated: true, processed: true,
      transaction_id: purchase[:transaction_id], original_transaction_id: purchase[:original_transaction_id],
      order_id: "ORD-#{SecureRandom.hex(6).upcase}", identifier: SecureRandom.uuid,
      date: purchase[:purchase_date],
      expires_date: if sub && purchase[:event_type] == Grovs::Purchases::EVENT_BUY
                      purchase[:purchase_date] + (purchase[:product_id].include?("annual") ? 365 : 30).days
                    else
                      nil
                    end,
      created_at: purchase[:purchase_date], updated_at: purchase[:purchase_date]
    }
  end

  def purchase_ch_row(purchase)
    {
      project_id: purchase[:project_id], event_type: purchase[:event_type],
      purchase_type: purchase[:purchase_type].to_s, product_id: purchase[:product_id].to_s,
      usd_price_cents: purchase[:usd_price_cents], currency: purchase[:currency].to_s,
      quantity: purchase[:quantity], transaction_id: purchase[:transaction_id],
      original_transaction_id: purchase[:original_transaction_id].to_s,
      store_source: purchase[:store_source].to_s,
      device_id: purchase[:device_id], link_id: purchase[:link_id] || 0, visitor_id: purchase[:visitor_id],
      purchase_date: purchase[:purchase_date], created_at: purchase[:purchase_date]
    }
  end

  # ============================================================
  # PG stats backfill (only for smaller runs)
  # ============================================================

  def backfill_link_daily_stats(project, links, start_time, end_time)
    date = start_time.to_date
    end_date = end_time.to_date
    count = 0
    while date <= end_date
      day_range = date.beginning_of_day..date.end_of_day
      links.each do |link|
        events = Event.where(project_id: project.id, link_id: link.id, created_at: day_range)
        next unless events.exists?
        events.group(:platform).count.each_key do |plat|
          plat_events = events.where(platform: plat)
          s = plat_events.group(:event).count
          LinkDailyStatistic.upsert({
            project_id: project.id, link_id: link.id, event_date: date, platform: plat,
            views: s[Grovs::Events::VIEW] || 0, opens: s[Grovs::Events::OPEN] || 0,
            installs: s[Grovs::Events::INSTALL] || 0, reinstalls: s[Grovs::Events::REINSTALL] || 0,
            app_opens: s[Grovs::Events::APP_OPEN] || 0, reactivations: s[Grovs::Events::REACTIVATION] || 0,
            time_spent: plat_events.where(event: Grovs::Events::TIME_SPENT).sum(:engagement_time),
            user_referred: s[Grovs::Events::USER_REFERRED] || 0,
            created_at: Time.current, updated_at: Time.current
          }, unique_by: :link_daily_statistics_pkey)
        end
        count += 1
      end
      date += 1.day
    end
    puts "  LinkDailyStatistic: #{count} link-days"
  end

  def backfill_visitor_daily_stats(project, dvs, start_time, end_time)
    dv_by_device = dvs.index_by { |d| d[:device].id }
    date = start_time.to_date
    end_date = end_time.to_date
    count = 0
    while date <= end_date
      day_range = date.beginning_of_day..date.end_of_day
      Event.where(project_id: project.id, created_at: day_range).select(:device_id).distinct.pluck(:device_id).each do |did|
        dv = dv_by_device[did]
        next unless dv
        events = Event.where(project_id: project.id, device_id: did, created_at: day_range)
        s = events.group(:event).count
        VisitorDailyStatistic.upsert({
          visitor_id: dv[:visitor].id, project_id: project.id, event_date: date, platform: dv[:platform],
          views: s[Grovs::Events::VIEW] || 0, opens: s[Grovs::Events::OPEN] || 0,
          installs: s[Grovs::Events::INSTALL] || 0, reinstalls: s[Grovs::Events::REINSTALL] || 0,
          app_opens: s[Grovs::Events::APP_OPEN] || 0, reactivations: s[Grovs::Events::REACTIVATION] || 0,
          time_spent: events.where(event: Grovs::Events::TIME_SPENT).sum(:engagement_time),
          user_referred: s[Grovs::Events::USER_REFERRED] || 0,
          created_at: Time.current, updated_at: Time.current
        }, unique_by: :uniq_vds_proj_visitor_date_platform)
        count += 1
      end
      date += 1.day
    end
    puts "  VisitorDailyStatistic: #{count} visitor-days"
  end

  def backfill_daily_project_metrics(project, start_time, end_time)
    date = start_time.to_date
    end_date = end_time.to_date
    count = 0
    while date <= end_date
      day_range = date.beginning_of_day..date.end_of_day
      events = Event.where(project_id: project.id, created_at: day_range)
      if events.exists?
        events.group(:platform).count.each_key do |plat|
          pe = events.where(platform: plat)
          s = pe.group(:event).count
          installs = s[Grovs::Events::INSTALL] || 0
          # Organic = installs with no link attribution; referred = installs via a
          # referral link (emit a USER_REFERRED event). The dashboard derives
          # link_driven_installs = installs - organic_users (campaigns + links + referrals).
          organic_users = pe.where(event: Grovs::Events::INSTALL, link_id: nil).count
          DailyProjectMetric.upsert({
            project_id: project.id, event_date: date, platform: plat,
            views: s[Grovs::Events::VIEW] || 0, link_views: s[Grovs::Events::VIEW] || 0,
            opens: s[Grovs::Events::OPEN] || 0, installs: installs,
            reinstalls: s[Grovs::Events::REINSTALL] || 0, app_opens: s[Grovs::Events::APP_OPEN] || 0,
            new_users: installs,
            organic_users: organic_users,
            referred_users: s[Grovs::Events::USER_REFERRED] || 0,
            first_time_visitors: pe.select(:device_id).distinct.count,
            created_at: Time.current, updated_at: Time.current
          }, unique_by: :idx_dpm_on_project_date_platform)
          count += 1
        end
      end
      date += 1.day
    end
    puts "  DailyProjectMetric: #{count} platform-days"
  end

  # Per-link revenue → LinkDailyStatistic.revenue (read by link_statistics_query).
  # Upserts only the revenue column; counter columns are left untouched (or
  # default to 0 when this creates a row the event backfill never touched, e.g.
  # a purchase attributed to a campaign link the session didn't otherwise hit).
  def backfill_link_revenue(project, purchases)
    agg = Hash.new(0)
    purchases.each do |p|
      next unless p[:link_id]
      agg[[p[:link_id], p[:purchase_date].to_date, p[:platform]]] += signed_revenue_cents(p)
    end
    count = 0
    agg.each do |(link_id, date, platform), revenue|
      next if revenue.zero?
      LinkDailyStatistic.upsert({
        project_id: project.id, link_id: link_id, event_date: date, platform: platform,
        revenue: revenue, created_at: Time.current, updated_at: Time.current
      }, unique_by: :link_daily_statistics_pkey)
      count += 1
    end
    puts "  LinkDailyStatistic revenue: #{count} link-days"
  end

  # Project-level revenue → DailyProjectMetric (read by DashboardMetrics):
  # revenue (signed), units_sold (buys), cancellations (cancels + non-sub refunds),
  # first_time_purchases (each device's earliest buy).
  def backfill_project_revenue(project, purchases)
    first_buy = {}
    purchases.select { |p| p[:event_type] == Grovs::Purchases::EVENT_BUY }
             .sort_by { |p| p[:purchase_date] }
             .each { |p| first_buy[p[:device_id]] ||= p }

    agg = Hash.new { |h, k| h[k] = { revenue: 0, units: 0, cancel: 0, ftp: 0 } }
    purchases.each do |p|
      key = [p[:purchase_date].to_date, p[:platform]]
      agg[key][:revenue] += signed_revenue_cents(p)
      agg[key][:units]   += p[:quantity] if p[:event_type] == Grovs::Purchases::EVENT_BUY
      agg[key][:cancel]  += p[:quantity] if counts_as_cancellation?(p)
    end
    first_buy.each_value { |p| agg[[p[:purchase_date].to_date, p[:platform]]][:ftp] += 1 }

    agg.each do |(date, platform), v|
      DailyProjectMetric.upsert({
        project_id: project.id, event_date: date, platform: platform,
        revenue: v[:revenue], units_sold: v[:units], cancellations: v[:cancel],
        first_time_purchases: v[:ftp],
        created_at: Time.current, updated_at: Time.current
      }, unique_by: :idx_dpm_on_project_date_platform)
    end
    puts "  DailyProjectMetric revenue: #{agg.size} platform-days"
  end

  # ============================================================
  # SDK setup
  # ============================================================

  def setup_sdk_integrations(instance, domain)
    app_name = instance.production.name.parameterize(separator: ".")
    ios_app = instance.application_for_platform(Grovs::Platforms::IOS)
    unless ios_app.ios_configuration
      IosConfiguration.create!(application: ios_app, bundle_id: "com.#{app_name}.ios", app_prefix: "SEED#{SecureRandom.hex(3).upcase}")
    end
    android_app = instance.application_for_platform(Grovs::Platforms::ANDROID)
    unless android_app.android_configuration
      AndroidConfiguration.create!(application: android_app, identifier: "com.#{app_name}.android")
    end
    web_app = instance.application_for_platform(Grovs::Platforms::WEB)
    unless web_app.web_configuration
      wc = WebConfiguration.create!(application: web_app)
      WebConfigurationLinkedDomain.create!(web_configuration: wc, domain: domain.full_domain)
    end
    instance.create_desktop_configuration
    puts "SDK integrations ensured (iOS, Android, Web, Desktop)"
  end

  # Returns a link matching the user's primary source, or nil for organic.
  def link_for_source(source, campaign_links, standalone_links, referral_links)
    case source
    when :organic   then nil
    when :campaigns then campaign_links.sample
    when :links     then standalone_links.any? ? standalone_links.sample : nil
    when :referrals then referral_links.any? ? referral_links.sample : nil
    end
  end

  def weighted_pick(options)
    r = rand
    cum = 0.0
    options.each do |k, w| 
      cum += w
      return k if r <= cum
    end
    options.keys.last
  end

  def random_sdk_attributes
    plans = %w[free starter pro enterprise]
    segments = %w[power_user casual new_user churned engaged]
    attrs = { "plan" => plans.sample, "segment" => segments.sample }
    attrs["age_group"] = %w[18-24 25-34 35-44 45-54 55+].sample if rand < 0.5
    attrs["company_size"] = %w[1-10 11-50 51-200 201-1000 1000+].sample if rand < 0.3
    attrs
  end

  # ============================================================
  # Data constants
  # ============================================================

  PLATFORM_WEIGHTS = { "ios" => 0.42, "android" => 0.35, "web" => 0.15, "desktop" => 0.08 }.freeze

  # Per-user acquisition source. Each user is assigned ONE primary source.
  # Organic users never touch a link. Campaign/link/referral users get their
  # attributed link on install + ~30% of return sessions.
  USER_SOURCE_WEIGHTS = { organic: 0.40, campaigns: 0.30, links: 0.18, referrals: 0.12 }.freeze

  APP_VERSIONS = %w[1.0.0 1.1.0 1.2.0 1.3.0 2.0.0 2.0.1 2.1.0 2.2.0 3.0.0].freeze
  BUILDS       = %w[100 110 120 130 200 201 210 220 300].freeze

  GEO_LOCATIONS = [
    # US
    { country: "US", city: "New York",      language: "en", timezone: "America/New_York",      ip: "72.229.28.#{rand(1..254)}" },
    { country: "US", city: "Los Angeles",   language: "en", timezone: "America/Los_Angeles",   ip: "104.132.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "US", city: "Chicago",       language: "en", timezone: "America/Chicago",       ip: "73.153.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "US", city: "San Francisco", language: "en", timezone: "America/Los_Angeles",   ip: "199.36.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "US", city: "Miami",         language: "en", timezone: "America/New_York",      ip: "65.34.#{rand(0..255)}.#{rand(1..254)}" },
    # UK
    { country: "GB", city: "London",        language: "en", timezone: "Europe/London",         ip: "86.156.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "GB", city: "Manchester",    language: "en", timezone: "Europe/London",         ip: "82.132.#{rand(0..255)}.#{rand(1..254)}" },
    # Germany
    { country: "DE", city: "Berlin",        language: "de", timezone: "Europe/Berlin",         ip: "91.64.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "DE", city: "Munich",        language: "de", timezone: "Europe/Berlin",         ip: "88.217.#{rand(0..255)}.#{rand(1..254)}" },
    # France
    { country: "FR", city: "Paris",         language: "fr", timezone: "Europe/Paris",          ip: "90.83.#{rand(0..255)}.#{rand(1..254)}" },
    # Japan
    { country: "JP", city: "Tokyo",         language: "ja", timezone: "Asia/Tokyo",            ip: "126.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "JP", city: "Osaka",         language: "ja", timezone: "Asia/Tokyo",            ip: "118.238.#{rand(0..255)}.#{rand(1..254)}" },
    # Brazil
    { country: "BR", city: "Sao Paulo",     language: "pt", timezone: "America/Sao_Paulo",    ip: "177.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "BR", city: "Rio de Janeiro", language: "pt", timezone: "America/Sao_Paulo",   ip: "189.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # India
    { country: "IN", city: "Mumbai",        language: "en", timezone: "Asia/Kolkata",          ip: "49.36.#{rand(0..255)}.#{rand(1..254)}" },
    { country: "IN", city: "Bangalore",     language: "en", timezone: "Asia/Kolkata",          ip: "103.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # Australia
    { country: "AU", city: "Sydney",        language: "en", timezone: "Australia/Sydney",      ip: "101.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # South Korea
    { country: "KR", city: "Seoul",         language: "ko", timezone: "Asia/Seoul",            ip: "175.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # Canada
    { country: "CA", city: "Toronto",       language: "en", timezone: "America/Toronto",       ip: "99.#{rand(224..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # Spain
    { country: "ES", city: "Madrid",        language: "es", timezone: "Europe/Madrid",         ip: "88.6.#{rand(0..255)}.#{rand(1..254)}" },
    # Italy
    { country: "IT", city: "Rome",          language: "it", timezone: "Europe/Rome",           ip: "79.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # Mexico
    { country: "MX", city: "Mexico City",   language: "es", timezone: "America/Mexico_City",   ip: "189.203.#{rand(0..255)}.#{rand(1..254)}" },
    # Netherlands
    { country: "NL", city: "Amsterdam",     language: "nl", timezone: "Europe/Amsterdam",      ip: "145.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
    # Sweden
    { country: "SE", city: "Stockholm",     language: "sv", timezone: "Europe/Stockholm",      ip: "83.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}" },
  ].freeze

  CAMPAIGN_CONFIGS = [
    { name: "Summer Sale 2026" },
    { name: "Product Hunt Launch" },
    { name: "Referral Program" },
    { name: "Black Friday 2026" },
    { name: "Email Newsletter" },
    { name: "Social Media Ads" },
    { name: "Influencer Partners" },
    { name: "App Store Feature" }
  ].freeze

  LINK_CONFIGS = [
    { path: "summer-sale",      name: "Summer Sale",           title: "Summer Sale",          subtitle: "Save 20% this summer",         
tags: ["campaign", "summer"],     data: { "promo" => "summer26", "discount" => "20%" },    source: "email",     medium: "newsletter" },
    { path: "new-feature",      name: "New Feature Launch",    title: "Try Our New Feature",  subtitle: "AI-powered search is here",    
tags: ["product", "launch"],      data: { "feature" => "ai_search" },                      source: "blog",      medium: "content" },
    { path: "invite",           name: "Invite a Friend",       title: "Invite a Friend",      subtitle: "Get a free month of Premium",  
tags: ["referral", "growth"],     data: { "reward" => "premium_month" },                   source: "app",       medium: "referral" },
    { path: "black-friday",     name: "Black Friday Deals",    title: "Black Friday Deals",   subtitle: "Up to 40% off everything",     
tags: ["campaign", "bfcm"],       data: { "promo" => "bf2026", "discount" => "40%" },      source: "ads",       medium: "paid" },
    { path: "onboarding",       name: "Get Started",           title: "Get Started",          subtitle: "Set up your account in 2 min", 
tags: ["onboarding"],             data: { "flow" => "new_user" },                          source: "app",       medium: "organic" },
    { path: "premium-upgrade",  name: "Premium Upgrade",       title: "Go Premium",           subtitle: "7-day free trial",              
tags: ["monetization", "upgrade"],data: { "plan" => "premium", "trial" => "7d" },          source: "email",     medium: "lifecycle" },
    { path: "weekly-digest",    name: "Weekly Digest",         title: "Your Weekly Digest",   subtitle: "This week's highlights",        
tags: ["engagement", "email"],    data: { "edition" => "weekly" },                         source: "email",     medium: "digest" },
    { path: "product-launch",   name: "Product Launch",        title: "New Product Drop",     subtitle: "Introducing Widget Pro",        
tags: ["product", "launch"],      data: { "product" => "widget_pro" },                     source: "social",    medium: "organic" },
    { path: "holiday-promo",    name: "Holiday Special",       title: "Holiday Special",      subtitle: "Limited time offer",            
tags: ["campaign", "holiday"],    data: { "promo" => "holiday26" },                        source: "ads",       medium: "display" },
    { path: "referral-bonus",   name: "Referral Bonus",        title: "Earn Referral Rewards",subtitle: "50 credits per referral",       
tags: ["referral", "rewards"],    data: { "bonus" => "50_credits" },                       source: "app",       medium: "referral" },
    { path: "podcast-sponsor",  name: "Podcast Offer",         title: "Podcast Special Offer",subtitle: "Use code PODCAST20",            
tags: ["campaign", "podcast"],    data: { "show" => "tech_talk", "code" => "PODCAST20" },  source: "podcast",   medium: "sponsorship" },
    { path: "twitter-launch",   name: "X/Twitter Launch",      title: "Follow Us on X",       subtitle: "Stay updated",                  
tags: ["social", "twitter"],      data: { "channel" => "twitter" },                        source: "twitter",   medium: "social" },
    { path: "tiktok-promo",     name: "TikTok Promo",          title: "TikTok Exclusive",     subtitle: "Creator collab deal",           
tags: ["social", "tiktok"],       data: { "channel" => "tiktok", "creator" => "viral_dev"},source: "tiktok",    medium: "influencer" },
    { path: "fb-retarget",      name: "Facebook Retarget",     title: "Come Back & Save",     subtitle: "We miss you! 15% off",          
tags: ["ads", "retargeting"],     data: { "audience" => "lapsed_30d" },                    source: "facebook",  medium: "retargeting" },
    { path: "google-search",    name: "Google Search Ad",      title: "Found via Search",     subtitle: "Top-rated productivity app",    
tags: ["ads", "search"],          data: { "keyword" => "best_app" },                       source: "google",    medium: "cpc" },
  ].freeze

  # In-app products for purchase event generation
  PRODUCTS = [
    { id: "com.app.premium.monthly",   type: "subscription", price_cents: 999 },
    { id: "com.app.premium.annual",    type: "subscription", price_cents: 7999 },
    { id: "com.app.pro.monthly",       type: "subscription", price_cents: 1999 },
    { id: "com.app.pro.annual",        type: "subscription", price_cents: 14999 },
    { id: "com.app.starter.monthly",   type: "subscription", price_cents: 499 },
    { id: "com.app.credits.100",       type: "one_time",     price_cents: 499 },
    { id: "com.app.credits.500",       type: "one_time",     price_cents: 1999 },
    { id: "com.app.credits.1000",      type: "one_time",     price_cents: 3499 },
    { id: "com.app.theme.premium",     type: "one_time",     price_cents: 299 },
    { id: "com.app.unlock.feature",    type: "one_time",     price_cents: 799 },
  ].freeze

  # Retention personas — control first-day screens, return frequency, AND how far
  # from install a user stays active. `max_active_days` caps the window for return
  # sessions so churners/bouncers don't accidentally appear retained at D30.
  #
  # Expected retention curve (approximate):
  #   D1: ~55%  D3: ~35%  D7: ~22%  D14: ~15%  D30: ~8%  D90: ~4%
  RETENTION_PERSONAS = {
    power_user: { first_day_screens: %w[home feed product_detail cart checkout],  return_probability: 0.60, max_active_days: nil },
    engaged:    { first_day_screens: %w[home feed product_detail wishlist share], return_probability: 0.35, max_active_days: 21 },
    casual:     { first_day_screens: %w[home feed notifications],                return_probability: 0.20, max_active_days: 4 },
    churner:    { first_day_screens: %w[home settings change_language],           return_probability: 0.08, max_active_days: 1 },
    bouncer:    { first_day_screens: %w[register onboarding forgot_password],     return_probability: 0.0,  max_active_days: 0 }
  }.freeze

  RETENTION_PERSONA_WEIGHTS = {
    power_user: 0.10, engaged: 0.15, casual: 0.25, churner: 0.30, bouncer: 0.20
  }.freeze

  # Realistic screen flows (sequences users actually navigate)
  SCREEN_FLOWS = [
    %w[home feed product_detail cart checkout payment_success],
    %w[home search product_detail product_detail wishlist],
    %w[home notifications feed profile edit_profile],
    %w[login home feed product_detail share],
    %w[onboarding home feed profile settings],
    %w[home categories search product_detail cart checkout],
    %w[home order_history product_detail rate_product],
    %w[home settings change_language settings profile],
    %w[home feed notifications feed product_detail],
    %w[register onboarding home feed product_detail cart],
    %w[home wishlist product_detail cart checkout payment_success order_history],
    %w[home profile settings payment_methods subscription],
    %w[forgot_password login home feed],
    %w[home deals product_detail product_detail cart checkout],
  ].freeze

  # Custom events with property generators
  CUSTOM_EVENTS = [
    { name: "add_to_cart",            props_generator: lambda {
      {
        "product_id" => "SKU-#{rand(1000..9999)}",
        "price" => rand(5.0..299.0).round(2),
        "currency" => %w[USD EUR GBP JPY BRL].sample,
        "quantity" => rand(1..5),
        "category" => %w[electronics clothing shoes accessories home_garden sports].sample
      }
    } },
    { name: "remove_from_cart",       props_generator: lambda {
      { "product_id" => "SKU-#{rand(1000..9999)}", "reason" => %w[changed_mind too_expensive found_better out_of_stock].sample }
    } },
    { name: "begin_checkout",         props_generator: lambda {
      {
        "cart_value" => rand(15.0..800.0).round(2),
        "item_count" => rand(1..12),
        "currency" => %w[USD EUR GBP].sample,
        "coupon" => rand < 0.4 ? %w[SAVE10 SAVE20 WELCOME FRIEND50 VIP25 SUMMER].sample : nil,
        "payment_method" => %w[credit_card apple_pay google_pay paypal].sample
      }.compact
    } },
    { name: "complete_purchase",      props_generator: lambda {
      {
        "order_id" => "ORD-#{SecureRandom.hex(4).upcase}",
        "total" => rand(10.0..500.0).round(2),
        "currency" => %w[USD EUR GBP].sample,
        "item_count" => rand(1..8),
        "is_first_purchase" => rand < 0.2,
        "payment_method" => %w[credit_card apple_pay google_pay paypal].sample
      }
    } },
    { name: "search_query",           props_generator: lambda {
      {
        "query" => %w[shoes jacket headphones laptop case charger watch band dress shirt camera lens keyboard mouse speaker].sample,
        "results_count" => rand(0..500),
        "category_filter" => rand < 0.3 ? %w[electronics clothing home].sample : nil,
        "sort_by" => %w[relevance price_asc price_desc rating newest].sample
      }.compact
    } },
    { name: "share_content",          props_generator: lambda {
      {
        "content_type" => %w[product article deal wishlist achievement].sample,
        "channel" => %w[whatsapp twitter instagram email sms telegram facebook clipboard].sample,
        "content_id" => "CTN-#{rand(100..9999)}"
      }
    } },
    { name: "rate_app",               props_generator: lambda {
      {
        "rating" => [1, 2, 3, 3, 4, 4, 4, 5, 5, 5].sample,
        "has_comment" => rand < 0.3,
        "app_version" => APP_VERSIONS.sample,
        "days_since_install" => rand(1..180)
      }
    } },
    { name: "invite_friend",          props_generator: lambda {
      { "method" => %w[sms email link qr_code share_sheet].sample, "reward_type" => %w[credits discount premium_trial].sample }
    } },
    { name: "view_promotion",         props_generator: lambda {
      {
        "promo_id" => "PROMO-#{rand(100..999)}",
        "placement" => %w[home_banner feed_card popup bottom_sheet interstitial].sample,
        "campaign" => %w[summer_sale new_user flash_deal loyalty vip].sample
      }
    } },
    { name: "click_banner",           props_generator: lambda {
      {
        "banner_id" => "BNR-#{rand(100..999)}",
        "position" => rand(1..6),
        "creative_variant" => %w[A B C].sample,
        "campaign" => %w[awareness conversion retention].sample
      }
    } },
    { name: "apply_filter",           props_generator: lambda {
      {
        "filter_type" => %w[price category brand color size rating availability].sample,
        "filter_value" => "val-#{rand(1..30)}",
        "results_before" => rand(50..500),
        "results_after" => rand(1..100)
      }
    } },
    { name: "toggle_dark_mode",       props_generator: -> { { "enabled" => [true, false].sample, "trigger" => %w[settings quick_toggle schedule].sample } } },
    { name: "signup_complete",        props_generator: lambda {
      {
        "method" => %w[email google apple facebook twitter sso].sample,
        "referral_code" => rand < 0.3 ? "REF-#{SecureRandom.hex(3).upcase}" : nil,
        "newsletter_opted_in" => rand < 0.6
      }.compact
    } },
    { name: "profile_updated",        props_generator: lambda {
      { "fields_changed" => %w[name email avatar bio location preferences].sample(rand(1..3)), "has_avatar" => rand < 0.5, "completeness" => rand(30..100) }
    } },
    { name: "subscription_started",   props_generator: lambda {
      {
        "plan" => %w[starter pro enterprise].sample,
        "billing_cycle" => %w[monthly annual].sample,
        "price" => [4.99, 9.99, 19.99, 49.99, 99.99].sample,
        "currency" => %w[USD EUR GBP].sample,
        "trial" => rand < 0.4
      }
    } },
    { name: "subscription_cancelled", props_generator: lambda {
      {
        "plan" => %w[starter pro enterprise].sample,
        "reason" => %w[too_expensive not_using missing_features switching competitor found_free_alternative].sample,
        "days_subscribed" => rand(1..365)
      }
    } },
    { name: "tutorial_step_complete", props_generator: lambda {
      { "step" => rand(1..8), "total_steps" => 8, "time_on_step_ms" => rand(2000..30_000), "skipped_steps" => rand(0..2) }
    } },
    { name: "notification_opened",    props_generator: lambda {
      {
        "notification_type" => %w[promo reminder social achievement system].sample,
        "notification_id" => "NOTIF-#{rand(1000..9999)}",
        "time_to_open_ms" => rand(1000..86_400_000)
      }
    } },
    { name: "error_encountered",      props_generator: lambda {
      {
        "error_code" => %w[E001 E002 E003 E404 E500 TIMEOUT NETWORK].sample,
        "screen" => %w[checkout payment profile search feed].sample,
        "retry_count" => rand(0..3),
        "resolved" => rand < 0.7
      }
    } },
    { name: "feature_flag_exposure",  props_generator: lambda {
      {
        "flag" => %w[new_checkout_flow ai_recommendations dark_mode_v2 social_feed redesigned_cart].sample,
        "variant" => %w[control treatment_a treatment_b].sample,
        "user_segment" => %w[new returning power_user].sample
      }
    } },
  ].freeze

  # Each entry pairs a user agent with compatible models so os/model never mismatch.
  PLATFORM_DATA = {
    "ios" => {
      device_variants: [
        { ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",        
models: ["iPhone 15 Pro Max", "iPhone 15 Pro", "iPhone 15"] },
        { ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",      
models: ["iPhone 14 Pro", "iPhone 14"] },
        { ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",      
models: ["iPhone 13", "iPhone SE (3rd gen)"] },
        { ua: "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",                 
models: ["iPad Pro 12.9", "iPad Air"] },
        { ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",        
models: ["iPhone 15 Pro Max", "iPhone 15 Pro"] }
      ],
      widths: [375, 390, 393, 414, 428, 430], heights: [667, 812, 844, 852, 896, 926, 932]
    },
    "android" => {
      device_variants: [
        { ua: "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.72 Mobile Safari/537.36",     
models: ["Pixel 8 Pro", "Pixel 8"] },
        { ua: "Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.72 Mobile Safari/537.36",        
models: ["Galaxy S24 Ultra", "Galaxy S24"] },
        { ua: "Mozilla/5.0 (Linux; Android 13; SM-A546B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36",        
models: ["Galaxy A54", "Galaxy S23 FE"] },
        { ua: "Mozilla/5.0 (Linux; Android 14; Pixel 7a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.72 Mobile Safari/537.36",        
models: ["Pixel 7a"] },
        { ua: "Mozilla/5.0 (Linux; Android 13; SM-G990B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.6312.99 Mobile Safari/537.36",        
models: ["OnePlus 12", "Nothing Phone 2"] }
      ],
      widths: [360, 384, 393, 412, 480], heights: [640, 800, 844, 915, 960]
    },
    "web" => {
      device_variants: [
        { ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",  
models: ["MacBook Pro 16", "MacBook Air M2", "iMac 24"] },
        { ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",       
models: ["ThinkPad X1 Carbon", "Dell XPS 15"] },
        { ua: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",                 
models: ["ThinkPad X1 Carbon", "Dell XPS 15"] }
      ],
      widths: [1280, 1440, 1536, 1920, 2560], heights: [720, 900, 864, 1080, 1440]
    },
    "desktop" => {
      device_variants: [
        { ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",  
models: ["Mac Studio", "Mac Mini M2"] },
        { ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0",                                      
models: ["Windows Desktop"] },
        { ua: "Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0",                                                
models: ["Linux Workstation"] }
      ],
      widths: [1920, 2560, 3440, 3840], heights: [1080, 1440, 1440, 2160]
    }
  }.freeze
end
