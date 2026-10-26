# frozen_string_literal: true

# Load-shaped local tenant: PG devices/visitors, CH events from a mapping table, then rollups. Dev only.
namespace :seed_bulk do
  desc "Generate a large synthetic audience (devices, visitors, events, profiles, purchases) for an instance"
  task generate: :environment do
    ActiveRecord::Base.logger.level = :warn
    abort "seed_bulk only runs in development" unless Rails.env.development?
    instance_id = ENV.fetch("INSTANCE_ID") do
      abort "Usage: rake seed_bulk:generate INSTANCE_ID=<id> CONFIRM=<id> [DEVICES=2000000] [EVENTS=30000000] [DAYS=90] " \
            "[PURCHASE_RATE=0.02] [ACTIVE_SHARE=0.55]"
    end
    abort "Refusing to wipe+seed instance #{instance_id}: re-run with CONFIRM=#{instance_id}" unless ENV["CONFIRM"] == instance_id
    abort "ClickHouse writes must be enabled" unless Clickhouse.enabled?

    devices_n = (ENV["DEVICES"] || 2_000_000).to_i
    events_n  = (ENV["EVENTS"] || 30_000_000).to_i
    days      = (ENV["DAYS"] || 90).to_i
    purchase_rate = (ENV["PURCHASE_RATE"] || 0.02).to_f
    active_share = (ENV["ACTIVE_SHARE"] || 0.55).to_f
    batch = (ENV["BATCH"] || 20_000).to_i

    instance = Instance.find(instance_id)
    project = instance.production or abort "No production project"
    pid = project.id
    now = Time.now.utc
    window_start = now - days.days
    run = SeedBulk::Run.new(pid, purchase_rate, window_start, now)
    say = run.say

    say.call("instance #{instance.id} project #{pid}: #{devices_n} devices, #{events_n} events, #{days} days")

    say.call("wiping Postgres rows for project #{pid}")
    Event.where(project_id: pid).in_batches(of: 50_000).delete_all
    PurchaseEvent.where(project_id: pid).delete_all
    LinkDailyStatistic.where(project_id: pid).delete_all
    VisitorDailyStatistic.where(project_id: pid).delete_all
    DailyProjectMetric.where(project_id: pid).delete_all
    DeviceLastSeen.where(project_id: pid).delete_all if defined?(DeviceLastSeen)
    project_visitors = Visitor.where(project_id: pid)
    # SDK referral links belong to the visitors being wiped; dashboard links are kept.
    Link.where(visitor_id: project_visitors.select(:id)).in_batches(of: 50_000).delete_all
    project_visitors.where.not(inviter_id: nil).in_batches(of: 50_000).update_all(inviter_id: nil)
    project_visitors.in_batches(of: 50_000).delete_all
    Device.where("vendor LIKE ?", "bulk-#{pid}-%").in_batches(of: 50_000) do |rel|
      InstalledApp.where(device_id: rel.select(:id)).delete_all if defined?(InstalledApp)
      rel.delete_all
    end

    say.call("wiping ClickHouse rows for project #{pid}")
    ch_tables = %w[events session_events session_summary user_profiles purchase_events visitor_identities visitor_identity_map
                   visitor_daily link_daily project_daily project_country_daily purchase_project_daily purchase_product_daily
                   visitor_first_seen_daily visitor_metrics_daily link_metrics_daily project_metrics_daily
                   visitor_last_touch_daily visitor_dimension_daily link_session_daily]
    Clickhouse.with do |conn|
      existing = conn.select_all("SELECT name FROM system.tables WHERE database = currentDatabase()").map { |r| r["name"] }
      (ch_tables & existing).each { |t| conn.execute("ALTER TABLE #{t} DELETE WHERE project_id = #{pid} SETTINGS mutations_sync = 2") }
      conn.execute("DROP TABLE IF EXISTS seed_visitors")
      conn.execute(<<~SQL)
        CREATE TABLE seed_visitors (
          idx UInt64, visitor_id UInt64, device_id UInt64,
          platform LowCardinality(String), os LowCardinality(String), os_version String, app_version String, build String,
          device_model String, language LowCardinality(String), country LowCardinality(String), city String, timezone String,
          sdk_identifier String, uuid String, sdk_attributes String, first_seen DateTime64(3, 'UTC'),
          link_id UInt64, campaign_id UInt64, tracking_source LowCardinality(String), tracking_medium LowCardinality(String),
          activity Float32
        ) ENGINE = MergeTree ORDER BY idx
      SQL
    end

    domain = project.domain or abort "No domain"
    campaigns = Campaign.where(project_id: pid).limit(8).to_a
    if campaigns.empty?
      campaigns = %w[Summer\ Sale Product\ Hunt Referral\ Program Black\ Friday Newsletter Social\ Ads Influencers Store\ Feature]
                  .map { |n| Campaign.create!(project: project, name: n) }
    end
    links = Link.where(domain_id: domain.id).where.not(campaign_id: nil).limit(20).to_a
    if links.empty?
      redirect_config = project.redirect_config || RedirectConfig.create!(project: project)
      links = campaigns.flat_map do |c|
        2.times.map do |i|
          Link.create!(domain: domain, campaign: c, redirect_config: redirect_config, name: "#{c.name} #{i + 1}",
                       path: "#{c.name.parameterize}-#{i + 1}-#{SecureRandom.hex(2)}", active: true,
                       generated_from_platform: %w[ios android web].sample)
        end
      end
    end
    link_pairs = links.map { |l| [l.id, l.campaign_id.to_i] }
    sources = [%w[google cpc], %w[facebook paid_social], %w[newsletter email], %w[tiktok paid_social], %w[organic organic], %w[twitter social]]

    platforms = [["ios", 45], ["android", 40], ["web", 12], ["mac", 3]]
    countries = [%w[US New\ York en America/New_York], %w[US Los\ Angeles en America/Los_Angeles], %w[GB London en Europe/London],
                 %w[DE Berlin de Europe/Berlin], %w[FR Paris fr Europe/Paris], %w[UA Kyiv uk Europe/Kyiv], %w[UA Lviv uk Europe/Kyiv],
                 %w[PL Warsaw pl Europe/Warsaw], %w[RO Bucharest ro Europe/Bucharest], %w[ES Madrid es Europe/Madrid],
                 %w[IT Rome it Europe/Rome], %w[BR Sao\ Paulo pt America/Sao_Paulo], %w[IN Mumbai en Asia/Kolkata],
                 %w[JP Tokyo ja Asia/Tokyo], %w[CA Toronto en America/Toronto], %w[AU Sydney en Australia/Sydney],
                 %w[NL Amsterdam nl Europe/Amsterdam], %w[SE Stockholm sv Europe/Stockholm], %w[MX Mexico\ City es America/Mexico_City],
                 %w[KR Seoul ko Asia/Seoul]]
    country_weights = [14, 8, 8, 7, 5, 12, 6, 6, 5, 4, 3, 5, 5, 3, 3, 2, 1, 1, 1, 1]
    versions = [["3.2.0", "320", 45], ["3.1.4", "314", 30], ["3.0.2", "302", 15], ["2.9.0", "290", 7], ["2.8.1", "281", 3]]
    models = { "ios" => %w[iPhone15,2 iPhone14,5 iPhone16,1 iPad13,1 iPhone12,1], "android" => %w[SM-S918B Pixel\ 8 SM-A546B Redmi\ Note\ 12 OnePlus\ 11],
               "web" => %w[Chrome Safari Firefox Edge], "mac" => %w[MacBookPro18,3 Mac14,2] }
    os_of = { "ios" => ["iOS", %w[17.5 17.4 18.0 16.7]], "android" => ["Android", %w[14 13 12 15]], "web" => ["Web", %w[126 125 17]],
"mac" => ["macOS", %w[14.5 15.0]] }
    plans = [["free", 70], ["pro", 22], ["enterprise", 8]]
    pick = lambda { |table|
      r = rand(table.sum(&:last))
      table.find { |t| (r -= t.last) < 0 }.first
    }
    pick_i = lambda { |weights|
      r = rand(weights.sum)
      weights.index { |w| (r -= w) < 0 }
    }

    say.call("inserting #{devices_n} devices and visitors into Postgres")
    inserted = 0
    idx = 0
    while inserted < devices_n
      n = [batch, devices_n - inserted].min
      rows = Array.new(n) do
        i = idx
        idx += 1
        platform = pick.call(platforms)
        c = countries[pick_i.call(country_weights)]
        ver = versions[pick_i.call(versions.map(&:last))]
        os_name, os_versions = os_of[platform]
        age_days = rand < 0.7 ? rand * days : days + rand * days * 2
        first_seen = now - age_days * 86_400
        identified = rand < 0.6
        plan = pick.call(plans)
        attrs = if identified
                  { "plan" => plan, "signup_source" => sources.sample.first, "age_group" => %w[18-24 25-34 35-44 45-54 55+].sample,
                "newsletter" => rand < 0.5, "credits" => rand(500) }
                else
                  {}
                end
        link_id, campaign_id = rand < 0.45 ? link_pairs.sample : [0, 0]
        src, med = if link_id.zero?
                     rand < 0.3 ? sources.sample : ["", ""]
                   else
                     sources.sample
                   end
        {
          i: i, platform: platform, os: os_name, os_version: os_versions.sample, app_version: ver[0], build: ver[1],
          model: models[platform].sample, language: c[2], country: c[0], city: c[1], timezone: c[3],
          sdk_identifier: identified ? "user_#{i}" : nil, attrs: attrs, first_seen: first_seen,
          link_id: link_id, campaign_id: campaign_id, src: src, med: med, activity: (rand**3).round(4)
        }
      end
      device_ids = Device.insert_all(rows.map do |r|
        { vendor: "bulk-#{pid}-#{r[:i]}", platform: r[:platform], app_version: r[:app_version], build: r[:build], model: r[:model],
          language: r[:language], timezone: r[:timezone], ip: "10.0.#{r[:i] / 256 % 256}.#{r[:i] % 256}", remote_ip: "10.0.#{r[:i] / 256 % 256}.#{r[:i] % 256}",
          user_agent: "bulk-seed/#{r[:platform]}", created_at: r[:first_seen], updated_at: r[:first_seen] }
      end, returning: [:id]).rows.flatten
      visitors = Visitor.insert_all(rows.each_with_index.map do |r, k|
        { device_id: device_ids[k], project_id: pid, sdk_identifier: r[:sdk_identifier], sdk_attributes: r[:attrs],
          web_visitor: r[:platform] == "web", created_at: r[:first_seen], updated_at: r[:first_seen] }
      end, returning: %i[id uuid]).rows
      ch_rows = rows.each_with_index.map do |r, k|
        { idx: r[:i], visitor_id: visitors[k][0], device_id: device_ids[k], platform: r[:platform], os: r[:os], os_version: r[:os_version],
          app_version: r[:app_version], build: r[:build], device_model: r[:model], language: r[:language], country: r[:country], city: r[:city],
          timezone: r[:timezone], sdk_identifier: r[:sdk_identifier].to_s, uuid: visitors[k][1].to_s, sdk_attributes: r[:attrs].to_json,
          first_seen: r[:first_seen].strftime("%Y-%m-%d %H:%M:%S.%L"), link_id: r[:link_id], campaign_id: r[:campaign_id],
          tracking_source: r[:src], tracking_medium: r[:med], activity: r[:activity] }
      end
      Clickhouse.with { |conn| conn.insert("seed_visitors", ch_rows) }
      inserted += n
      say.call("  #{inserted}/#{devices_n}") if (inserted / batch) % 10 == 0 || inserted == devices_n
    end

    ws = window_start.strftime("%Y-%m-%d %H:%M:%S.%L")
    nw = now.strftime("%Y-%m-%d %H:%M:%S.%L")
    ch = run.ch
    count = run.count

    say.call("generating install events")
    ch.call(<<~SQL)
      INSERT INTO events (event_id, project_id, event_type, device_id, visitor_id, link_id, campaign_id, platform, app_version, build, vendor_id,
                          device_model, os, os_version, timezone, language, country, city, tracking_source, tracking_medium,
                          sdk_identifier, sdk_attributes, session_id, created_at, ingested_at)
      SELECT lower(hex(MD5(concat('install-', toString(idx))))), #{pid}, 'install', device_id, visitor_id, link_id, campaign_id, platform,
             app_version, build, concat('bulk-', toString(idx)), device_model, os, os_version, timezone, language, country, city,
             tracking_source, tracking_medium, sdk_identifier, CAST(sdk_attributes, 'JSON'),
             concat('s', toString(idx), '-0'), first_seen, first_seen
      FROM seed_visitors WHERE first_seen >= toDateTime64('#{ws}', 3, 'UTC')
    SQL

    say.call("generating #{events_n} activity events")
    names = "['checkout','add_to_cart','signup','search','share','level_up','tutorial_done','invite_sent']"
    cats = "['shoes','electronics','books','games','beauty','sports']"
    ch.call(<<~SQL)
      INSERT INTO events (event_id, project_id, event_type, event_name, screen_name, device_id, visitor_id, link_id, campaign_id, platform,
                          app_version, build, vendor_id, device_model, os, os_version, timezone, language, country, city,
                          sdk_identifier, sdk_attributes, session_id, engagement_time, properties, created_at, ingested_at)
      SELECT
        lower(hex(MD5(concat('act-', toString(n))))), #{pid}, et,
        if(et = 'custom', arrayElement(#{names}, 1 + r2 % 8), ''),
        if(et = 'screen_view', arrayElement(['Home','Feed','Profile','Cart','Settings','Search'], 1 + r2 % 6), ''),
        sv.device_id, sv.visitor_id,
        if(et IN ('view','open'), sv_link, 0), if(et IN ('view','open'), sv_camp, 0),
        sv.platform, sv.app_version, sv.build, concat('bulk-', toString(sv.idx)), sv.device_model, sv.os, sv.os_version, sv.timezone,
        sv.language, sv.country, sv.city, sv.sdk_identifier, CAST(sv.sdk_attributes, 'JSON'),
        concat('s', toString(sv.idx), '-', toString(intDiv(toUnixTimestamp(ts), 1800))),
        if(et = 'time_spent', 5 + r3 % 900, 0),
        CAST(if(et = 'custom', concat('{"value":', toString(r3 % 200), ',"category":"', arrayElement(#{cats}, 1 + r3 % 6), '","quantity":', toString(1 + r3 % 4), '}'), '{}'), 'JSON'),
        ts, ts
      FROM (
        SELECT n, idx, r2, r3,
          multiIf(r1 < 50, 'app_open', r1 < 65, 'time_spent', r1 < 75, 'screen_view', r1 < 82, 'view', r1 < 88, 'open', r1 < 98, 'custom', 'reactivation') AS et,
          sv.link_id AS sv_link, sv.campaign_id AS sv_camp,
          greatest(sv.first_seen, toDateTime64('#{ws}', 3, 'UTC')) + toIntervalMillisecond(toUInt64(frac * (toUnixTimestamp64Milli(toDateTime64('#{nw}', 3, 'UTC')) - toUnixTimestamp64Milli(greatest(sv.first_seen, toDateTime64('#{ws}', 3, 'UTC')))))) AS ts
        FROM (
          SELECT number AS n,
            toUInt64(floor(pow(rand(number) / 4294967296.0, 2.2) * #{(devices_n * active_share).to_i})) AS idx,
            rand(number + 1) % 100 AS r1, rand(number + 2) AS r2, rand(number + 3) AS r3,
            pow(rand(number + 4) / 4294967296.0, 0.7) AS frac
          FROM numbers(#{events_n})
        ) AS x
        JOIN seed_visitors AS sv ON sv.idx = x.idx
      ) AS e
      JOIN seed_visitors AS sv ON sv.idx = e.idx
      SETTINGS max_insert_threads = 4, max_threads = 8, join_algorithm = 'hash'
    SQL
    say.call("events in ClickHouse: #{count.call("SELECT count() FROM events WHERE project_id = #{pid}")}")

    SeedBulk.finish(run)
  end

  desc "Resume a bulk seed after the events step (profiles, purchases, identities, rollups) using the existing seed_visitors table"
  task finish: :environment do
    ActiveRecord::Base.logger.level = :warn
    instance_id = ENV.fetch("INSTANCE_ID") { abort "Usage: rake seed_bulk:finish INSTANCE_ID=<id> [DAYS=90] [PURCHASE_RATE=0.02]" }
    days = (ENV["DAYS"] || 90).to_i
    purchase_rate = (ENV["PURCHASE_RATE"] || 0.02).to_f
    abort "seed_bulk only runs in development" unless Rails.env.development?
    pid = Instance.find(instance_id).production.id
    now = Time.now.utc
    run = SeedBulk::Run.new(pid, purchase_rate, now - days.days, now)
    abort "seed_visitors is missing: run seed_bulk:generate first" if run.count.call("SELECT count() FROM seed_visitors").to_i.zero?
    run.say.call("events in ClickHouse: #{run.count.call("SELECT count() FROM events WHERE project_id = #{pid}")}")
    SeedBulk.finish(run)
  end
end

module SeedBulk
  Run = Struct.new(:pid, :purchase_rate, :window_start, :now) do
    def t0 = @t0 ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def say = ->(msg) { puts format("[%<t>6.0fs] %<m>s", t: Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, m: msg) }
    def ch = ->(sql) { Clickhouse.with_request_timeout(3600) { Clickhouse.with { |conn| conn.execute(sql) } } }
    def count = ->(sql) { Clickhouse.with { |conn| conn.select_value(sql) } }
  end

  module_function

  def finish(run)
    pid = run.pid
    purchase_rate = run.purchase_rate
    say = run.say
    ch = run.ch
    count = run.count
    ws = run.window_start.strftime("%Y-%m-%d %H:%M:%S.%L")
    nw = run.now.strftime("%Y-%m-%d %H:%M:%S.%L")
    say.call("generating user_profiles")
    ch.call(<<~SQL)
      INSERT INTO user_profiles (project_id, visitor_id, sdk_identifier, properties, first_seen, last_seen, country, platform, inviter_id, uuid)
      SELECT #{pid}, sv.visitor_id, sv.sdk_identifier, CAST(sv.sdk_attributes, 'JSON'), sv.first_seen,
             greatest(sv.first_seen, ifNull(ls.last_seen, sv.first_seen)), sv.country, sv.platform, 0, sv.uuid
      FROM seed_visitors AS sv
      LEFT JOIN (SELECT visitor_id, max(created_at) AS last_seen FROM events WHERE project_id = #{pid} GROUP BY visitor_id) AS ls
        ON ls.visitor_id = sv.visitor_id
      SETTINGS max_threads = 8
    SQL

    say.call("generating purchases (#{(purchase_rate * 100).round(2)}% of visitors)")
    ch.call(<<~SQL)
      INSERT INTO purchase_events (project_id, event_type, purchase_type, product_id, usd_price_cents, currency, quantity, transaction_id,
                                   original_transaction_id, store_source, device_id, link_id, visitor_id, purchase_date, created_at, recorded_at, platform)
      SELECT #{pid}, 'buy',
        if(r % 3 = 0, 'subscription', 'one_time') AS purchase_type,
        if(r % 3 = 0, arrayElement(['premium_monthly','premium_yearly','plus_monthly'], 1 + r % 3), arrayElement(['coins_100','coins_500','skin_pack','remove_ads'], 1 + r % 4)),
        if(r % 3 = 0, arrayElement([999, 5999, 499], 1 + r % 3), arrayElement([199, 799, 299, 399], 1 + r % 4)),
        'USD', 1, concat('bulk-tx-', toString(idx), '-', toString(k)), concat('bulk-tx-', toString(idx), '-', toString(k)),
        multiIf(platform = 'ios', 'apple', platform = 'android', 'google', ''), device_id, link_id, visitor_id, ts, ts, ts, platform
      FROM (
        SELECT idx, k, platform, device_id, link_id, visitor_id, rand(idx * 7 + k) AS r,
          greatest(first_seen, toDateTime64('#{ws}', 3, 'UTC')) + toIntervalSecond(toUInt64((rand(idx * 11 + k) / 4294967296.0) * greatest(1, toUnixTimestamp(toDateTime64('#{nw}', 3, 'UTC')) - toUnixTimestamp(greatest(first_seen, toDateTime64('#{ws}', 3, 'UTC')))))) AS ts
        FROM seed_visitors
        ARRAY JOIN range(1 + rand(idx * 3) % 3) AS k
        WHERE rand(idx * 5) / 4294967296.0 < #{purchase_rate}
      )
    SQL

    say.call("syncing visitor identities")
    Analytics::VisitorIdentitySyncService.sync_project(pid)

    from = run.window_start.strftime("%Y%m")
    to = run.now.strftime("%Y%m")
    say.call("rebuilding rollups #{from}..#{to}")
    Clickhouse.with_request_timeout(3600) { ClickhouseRollupRebuildService.rebuild_partition_range(from, to, strict: true, fail_on_skip: true) }

    say.call("=== Done ===")
    %w[events user_profiles purchase_events visitor_identities visitor_daily visitor_first_seen_daily].each do |t|
      puts format("  %<t>-26s %<n>s", t: t, n: count.call("SELECT count() FROM #{t} WHERE project_id = #{pid}"))
    end
    puts format("  %<t>-26s %<n>s", t: "pg visitors", n: Visitor.where(project_id: pid).count)
  end
end
