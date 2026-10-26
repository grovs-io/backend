# frozen_string_literal: true

# Push campaign load tests against the push sink; runbook: docs/push-load-testing.md.
namespace :push_load do
  desc "Point an instance's iOS and Android apps at the push sink with generated credentials: INSTANCE_ID= CONFIRM="
  task(setup: :environment) { PushLoad.setup! }

  desc "Give the instance's bulk-seeded iOS and Android devices fake push tokens (restores dropped ones): INSTANCE_ID= CONFIRM="
  task(tokens: :environment) { PushLoad.tokens! }

  desc "Create a segment of every iOS and/or Android person: INSTANCE_ID= CONFIRM= [PLATFORMS=ios,android] [COUNTRIES=RO,DE]"
  task(segment: :environment) { PushLoad.segment! }

  desc "Send a campaign now: INSTANCE_ID= CONFIRM= SEGMENT=<hashid> [LINK_ID=] [IMAGE_URL=] [LOCAL_TIME_AT=<iso8601> TIMEZONE=]"
  task(send: :environment) { PushLoad.send! }

  desc "Export visitors to tap for the open storm: INSTANCE_ID= CAMPAIGN=<hashid> [RATE=0.05] [OUT=tmp/push_open_targets.json]"
  task(open_targets: :environment) { PushLoad.open_targets! }

  desc "Check a campaign against the sink: INSTANCE_ID= CAMPAIGN=<hashid> [SINK_STATS=http://localhost:4010/stats] [OPENS_SENT=]"
  task(report: :environment) { PushLoad.report! }
end

module PushLoad
  NEVER_QUEUED = %w[no_app no_token].freeze

  module_function

  def setup!
    guard!(writes: true)
    refuse_real_push_configs!
    ios = ios_config || config_for(Grovs::Platforms::IOS, bundle_id: "io.grovs.pushload", app_prefix: "PUSHLOAD01")
    android = android_config || config_for(Grovs::Platforms::ANDROID, identifier: "io.grovs.pushload")
    ios.ios_push_configuration&.destroy!
    android.android_push_configuration&.destroy!

    suffix = SecureRandom.hex(4)
    IosPushConfiguration.new(name: "#{PushSink::APP_PREFIX}ios-#{suffix}", certificate_password: "PUSHLOADK1", ios_configuration: ios).tap do |c|
      c.certificate.attach(blob("push-load.p8", OpenSSL::PKey::EC.generate("prime256v1").private_to_pem))
      c.save!
    end
    AndroidPushConfiguration.new(name: "#{PushSink::APP_PREFIX}android-#{suffix}", firebase_project_id: PushSink::FIREBASE_PROJECT_ID,
                                 android_configuration: android).tap do |c|
      c.certificate.attach(blob("push-load.json", fake_service_account))
      c.save!
    end

    puts "Instance #{instance.id} pushes through the sink: rpush apps #{rpush_apps(project).map(&:name).join(', ')}"
    puts "Production project #{project.id}, SDK key #{project.identifier}, iOS #{ios.bundle_id}, Android #{android.identifier}"
    puts "Start rpush with PUSH_SINK_APNS_URL and PUSH_SINK_FCM_URL set, or these pushes go to Apple and Google."
  end

  def tokens!
    guard!(writes: true)
    refuse_real_push_configs!
    # Deterministic per device, so the sink's error injection hits the same devices on every run.
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, "bulk-#{project.id}-%"])
      UPDATE devices SET push_token = CASE platform
          WHEN 'ios' THEN encode(sha256(convert_to(vendor, 'UTF8')), 'hex')
          ELSE 'plfcm-' || encode(sha256(convert_to(vendor, 'UTF8')), 'hex') END
      WHERE vendor LIKE ? AND platform IN ('ios', 'android')
    SQL
    puts "#{ActiveRecord::Base.connection.exec_update(sql)} devices of project #{project.id} have push tokens"
  end

  def segment!
    guard!(writes: true)
    platforms = ENV.fetch("PLATFORMS", "ios,android").split(",")
    conditions = [{ type: "device", field: "platform", op: "is", value: platforms, mode: "current" }]
    countries = ENV["COUNTRIES"].to_s.split(",")
    conditions << { type: "device", field: "country", op: "is", value: countries, mode: "current" } if countries.any?
    segment = project.segments.create!(name: "Push load: #{(platforms + countries).join('+')}",
                                       definition: { version: 1, operator: "and", groups: [{ operator: "and", conditions: conditions }] })
    puts "Segment #{segment.hashid}"
  end

  def send!
    guard!(writes: true)
    refuse_real_push_configs!
    params = { title: "Push load #{Time.current.utc.strftime('%H:%M:%S')}", body: "Load test", sound: "default",
               data: { "load" => "1" }, link_id: ENV["LINK_ID"].presence, image_url: ENV["IMAGE_URL"].presence,
               audience: { type: "segment", segment_id: ENV.fetch("SEGMENT") { abort "SEGMENT=<hashid> required" } } }.compact
    if ENV["LOCAL_TIME_AT"].present?
      params.merge!(scheduled_at: ENV["LOCAL_TIME_AT"], local_time: true, timezone: ENV.fetch("TIMEZONE", "UTC"))
    end
    campaign = PushCampaigns::ApiCreate.call(project: project, params: params)
    puts "Campaign #{campaign.hashid} (#{campaign.status})"
  end

  def open_targets!
    guard!
    rate = Float(ENV.fetch("RATE", "0.05"))
    out = ENV.fetch("OUT", Rails.root.join("tmp/push_open_targets.json").to_s)
    rows = campaign.deliveries.where(status: "delivered").where("random() < ?", rate)
                   .where.not(visitor_id: nil).pluck(:visitor_id, :platform)
    File.write(out, JSON.generate(
                      campaign_id: campaign.hashid, project_key: project.identifier,
                      identifiers: { "ios" => ios_config&.bundle_id, "android" => android_config&.identifier },
                      targets: rows.map { |visitor_id, platform| { id: Visitor.encode_id(visitor_id), platform: platform } }
                    ))
    puts "#{rows.size} targets written to #{out}"
  end

  def report!
    guard!
    report = campaign.reload.report
    deliveries = campaign.deliveries.group(:status).count
    print_report(report, deliveries)

    checks = report_checks(report, deliveries)
    if (stats = sink_stats)
      mine = stats.dig("campaigns", campaign.hashid) || {}
      puts "\nsink (this campaign): #{mine.except('samples').to_json}"
      checks.concat(sink_checks(report, mine))
    end

    puts "\nchecks:"
    ok = checks.map do |name, expected, actual|
      puts format("  %<r>-4s %<name>-38s expected %<e>-10s actual %<a>s", r: expected == actual ? "ok" : "FAIL", name: name, e: expected, a: actual)
      expected == actual
    end.all?
    puts(ok ? "\nall checks passed" : "\nsome checks failed (a campaign still sending settles over time; re-run once it is sent)")
  end

  def report_checks(report, deliveries)
    checks = [["queued = delivered + failed", report[:queued].to_i, report[:delivered].to_i + failed_after_queue(report)]]
    checks << ["no pending or claimed deliveries", 0, deliveries.slice("pending", "claimed").values.sum] if campaign.status == "sent"
    checks << ["opened = taps recorded", Integer(ENV["OPENS_SENT"]), report[:opened].to_i] if ENV["OPENS_SENT"].present?
    checks
  end

  def sink_checks(report, mine)
    checks = [["delivered = sink unique 200s", mine["accepted_unique"].to_i, report[:delivered].to_i],
              ["no device accepted twice", 0, mine["duplicate_deliveries"].to_i],
              ["failed = sink unique final errors", mine["rejected_unique"].to_i, failed_after_queue(report)]]
    dead = mine["dead_unique"].to_i
    if dead.positive?
      dead_devices = campaign.deliveries.where(status: "failed", error: %w[Unregistered BadDeviceToken 404]).select(:device_id)
      cleared = Device.where(id: dead_devices, push_token: nil).count
      checks << ["dead tokens cleared (at least)", dead, [cleared, dead].min]
    end
    checks
  end

  def failed_after_queue(report) = report[:failed].to_i - report[:error_counts].slice(*NEVER_QUEUED).values.sum.to_i

  def print_report(report, deliveries)
    span = ->(a, b) { a && b ? format("%.1fs", b - a) : "-" }
    puts "campaign #{campaign.hashid} status=#{campaign.status} #{campaign.failure_reason}"
    puts "  created→evaluated #{span.call(campaign.created_at, campaign.evaluated_at)}, " \
         "evaluated→handed to rpush #{span.call(campaign.evaluated_at, campaign.finished_at)}"
    puts "  report #{report.except(:audience).to_json}"
    puts "  audience #{report[:audience].to_json}"
    puts "  deliveries by status #{deliveries.sort.to_h}"
    backlog = Rpush::Notification.where(app_id: rpush_apps(project).map(&:id), delivered: false, failed: false).count
    puts "  rpush backlog (load apps, every campaign) #{backlog}"
  end

  def guard!(writes: false)
    abort "push_load runs in development, or with PUSH_LOAD_ALLOW=1 on a load-test stack" unless Rails.env.development? || ENV["PUSH_LOAD_ALLOW"] == "1"
    return unless writes
    return if ENV["CONFIRM"].present? && ENV["CONFIRM"] == ENV["INSTANCE_ID"]

    abort "Re-run with CONFIRM=#{ENV['INSTANCE_ID']} to write to instance #{ENV['INSTANCE_ID']}"
  end

  def refuse_real_push_configs!
    [ios_config&.ios_push_configuration, android_config&.android_push_configuration].compact.each do |push|
      abort "Instance #{instance.id} has real push credentials (#{push.name}); refusing to replace them" unless push.name.start_with?(PushSink::APP_PREFIX)
    end
  end

  def ios_config = instance.reload.ios_application&.ios_configuration
  def android_config = instance.reload.android_application&.android_configuration

  def config_for(platform, **params)
    PlatformConfigurationService.set_configuration(instance: instance, platform: platform, enabled: true, config_params: params)
    platform == Grovs::Platforms::IOS ? ios_config : android_config
  end

  # Uploaded before attaching: the create callback builds the rpush app from the stored file.
  def blob(name, content) = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename: name)

  def fake_service_account
    { type: "service_account", project_id: PushSink::FIREBASE_PROJECT_ID, client_email: "sink@#{PushSink::FIREBASE_PROJECT_ID}.iam.gserviceaccount.com",
      private_key: OpenSSL::PKey::RSA.generate(2048).private_to_pem }.to_json
  end

  def instance
    @instance ||= Instance.redis_find_by(:id, ENV.fetch("INSTANCE_ID") { abort "INSTANCE_ID=<id> required" }) or abort "Instance not found"
  end
  def project = instance.production

  def campaign
    @campaign ||= project.push_campaigns.find_by_hashid(ENV.fetch("CAMPAIGN") { abort "CAMPAIGN=<hashid> required" }) or abort "Campaign not found"
  end

  def rpush_apps(project) = PushCampaign::PUSH_PLATFORMS.filter_map { |p| RpushService.app_for_platform(p, project) }

  def sink_stats
    url = ENV.fetch("SINK_STATS", "http://localhost:4010/stats")
    JSON.parse(Net::HTTP.get(URI(url)))
  rescue StandardError => e
    puts "\nsink stats unavailable at #{url} (#{e.class}); skipping sink checks"
    nil
  end
end
