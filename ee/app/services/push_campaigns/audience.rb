module PushCampaigns
  class Audience
    IDENTIFIER_DEVICE_CAP = 50
    PAGE = 10_000
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DEVICE_COLUMNS = Arel.sql("visitors.id, visitors.device_id, devices.platform, NULLIF(devices.push_token, '') IS NOT NULL, devices.timezone")

    def self.freeze!(campaign, due_at: Time.current)
      new(campaign, due_at).freeze!
    end

    def self.estimate(campaign)
      return segment_estimate(campaign) if campaign.audience_type == "segment"

      recipients = Array(campaign.recipients).uniq
      rows, matched = case campaign.audience_type
                      when "visitors"
                        recipients = recipients.map(&:downcase).uniq # Postgres matches uuids case-insensitively
                        r = Visitor.joins(:device).where(project_id: campaign.project_id, uuid: recipients.grep(UUID)).order(:id)
                                   .pluck(Arel.sql("visitors.uuid, #{DEVICE_COLUMNS}"))
                        [r.map { |x| x.drop(1) }, r.map(&:first)]
                      when "identifiers"
                        r = Visitor.joins(:device).where(project_id: campaign.project_id, sdk_identifier: recipients).order(:id)
                                   .pluck(Arel.sql("visitors.sdk_identifier, #{DEVICE_COLUMNS}"))
                        capped = r.group_by(&:first).flat_map { |_, g| g.first(IDENTIFIER_DEVICE_CAP).map { |x| x.drop(1) } }
                        [capped, r.map(&:first)]
                      else
                        [[], []]
                      end
      list_estimate(rows, recipients, matched, configured_platforms(campaign.project))
    end

    def self.configured_platforms(project)
      PushCampaign::PUSH_PLATFORMS.index_with { |p| RpushService.app_for_platform(p, project).present? }
    end
    private_class_method :configured_platforms

    def self.list_estimate(rows, recipients, matched, configured)
      with_channel = rows.select { |_, _, platform, has_token, _| has_token && PushCampaign::PUSH_PLATFORMS.include?(platform) }
      by_platform = PushCampaign::PUSH_PLATFORMS.index_with { |p| with_channel.count { |_, _, plat, *| plat == p } }
      { devices: rows.size, no_channel: rows.size - with_channel.size, not_found: (recipients - matched.uniq).size,
        **reach_fields(by_platform, configured) }
    end
    private_class_method :list_estimate

    # No push-token data in ClickHouse: reachable here just means "on a configured push platform".
    def self.segment_estimate(campaign)
      size = Segments.estimate_with_platforms(campaign.project, campaign.segment)
      configured = configured_platforms(campaign.project)
      by_platform = { Grovs::Platforms::IOS => size[:ios_devices], Grovs::Platforms::ANDROID => size[:android_devices] }
      { devices: size[:devices], no_channel: 0, not_found: 0, persons: size[:persons], incomplete: size[:incomplete],
        **reach_fields(by_platform, configured) }
    end
    private_class_method :segment_estimate

    # A nil count means the CH split was unavailable (too heavy); no_app/reachable are unknown too.
    def self.reach_fields(by_platform, configured)
      return unavailable_reach_fields(by_platform, configured) if by_platform.value?(nil)

      { no_app: by_platform.sum { |p, n| configured[p] ? 0 : n },
        reachable: by_platform.sum { |p, n| configured[p] ? n : 0 },
        platforms: by_platform.to_h { |p, n| [p, { devices: n, configured: configured[p] }] } }
    end
    private_class_method :reach_fields

    def self.unavailable_reach_fields(by_platform, configured)
      { no_app: nil, reachable: nil, platforms: by_platform.to_h { |p, _| [p, { devices: nil, configured: configured[p] }] } }
    end
    private_class_method :unavailable_reach_fields

    def initialize(campaign, due_at)
      @campaign = campaign
      @due_at = due_at
      @now = Time.current
      @due_by_zone = {}
    end

    def freeze!
      @campaign.deliveries.where(status: "not_found").delete_all
      case @campaign.audience_type
      when "visitors" then freeze_visitors
      when "identifiers" then freeze_identifiers
      when "segment" then freeze_segment
      else raise ArgumentError, "unsupported audience #{@campaign.audience_type}"
      end
      totals
    end

    private

    def freeze_visitors
      recipients = Array(@campaign.recipients).map(&:downcase).uniq # Postgres matches uuids case-insensitively
      rows = Visitor.joins(:device).where(project_id: @campaign.project_id, uuid: recipients.grep(UUID)).order(:id)
                    .pluck(Arel.sql("visitors.uuid, #{DEVICE_COLUMNS}"))
      uuid_of = rows.to_h { |uuid, visitor_id, *| [visitor_id, uuid] }
      insert(rows.map { |r| r.drop(1) }) { |visitor_id| uuid_of[visitor_id] }
      not_found(recipients - uuid_of.values)
    end

    def freeze_identifiers
      identifiers = Array(@campaign.recipients).uniq
      rows = Visitor.joins(:device).where(project_id: @campaign.project_id, sdk_identifier: identifiers)
                    .order(:id).pluck(Arel.sql("visitors.sdk_identifier, #{DEVICE_COLUMNS}"))
      per_identifier = Hash.new(0)
      recipient_of = {}
      kept = rows.filter_map do |identifier, *row|
        next if (per_identifier[identifier] += 1) > IDENTIFIER_DEVICE_CAP

        recipient_of[row[0]] = identifier
        row
      end
      insert(kept) { |visitor_id| recipient_of[visitor_id] }
      not_found(identifiers - per_identifier.keys)
    end

    # Pages in visitor_id order; the unique index drops effective ids repeated across pages.
    def freeze_segment
      definition = Segments::Definition.parse(@campaign.segment_definition, cutoff_date: nil)
      manifest = Segments::Results.for(project: @campaign.project, definition: definition, list_generation: @campaign.segment_list_generation,
                                       segment_id: @campaign.segment_id, lane: :campaigns)
      @campaign.update!(audience_persons: manifest.persons, audience_devices: manifest.devices, audience_incomplete: manifest.incomplete)
      after = 0
      loop do
        page = Segments::Runner.read("SELECT visitor_id, eff_visitor_id FROM segment_results WHERE #{Segments::Results.scope_sql(manifest)} " \
                                     "AND visitor_id > #{Integer(after)} ORDER BY visitor_id LIMIT #{PAGE}")
        break if page.empty?

        ids = page.map { |r| Integer(r["eff_visitor_id"]) }.uniq
        rows = Visitor.joins(:device).where(project_id: @campaign.project_id, id: ids).order(:id).pluck(DEVICE_COLUMNS)
        insert(rows) { "segment" }
        after = Integer(page.last["visitor_id"])
      end
    end

    def due_for(device_timezone)
      return @due_at unless @campaign.local_time

      @due_by_zone[device_timezone.to_s] ||= begin
        zone = ActiveSupport::TimeZone[device_timezone.to_s] || @campaign.zone
        wall = @campaign.scheduled_at.in_time_zone(@campaign.zone).strftime("%Y-%m-%d %H:%M:%S")
        [zone.parse(wall), Time.current].max
      end
    end

    def insert(rows)
      return if rows.empty?

      held = []
      exposed = []
      attrs = rows.map do |visitor_id, device_id, platform, has_token, timezone|
        status, variant, scope = place(visitor_id, has_token && PushCampaign::PUSH_PLATFORMS.include?(platform))
        due = due_for(timezone)
        # A local-time row goes out up to a day after the freeze; the conversion window opens when it is due.
        at = @campaign.local_time ? due : @now
        held << [device_id, { "campaign_id" => @campaign.hashid, "scope" => scope }, at] if scope
        exposed << [device_id, { "campaign_id" => @campaign.hashid, "variant" => variant }, at] if status == "pending"
        { push_campaign_id: @campaign.id, visitor_id: visitor_id, device_id: device_id, platform: platform, variant: variant,
          recipient: yield(visitor_id), due_at: due, created_at: @now, updated_at: @now, status: status }
      end
      PushDelivery.insert_all(attrs, unique_by: :index_push_deliveries_on_campaign_and_visitor)
      expose(Experiments::Held::PUSH, held)
      expose(Experiments::Held::PUSH_DELIVERED, exposed) if @campaign.measured?
    end

    def expose(name, rows)
      rows.group_by(&:last).each { |at, list| Experiments::Held.push(@campaign.project_id, name, list.map { |device, props, _| [device, props] }, at: at) }
    end

    # Status, variant and, for a person kept back, the scope they were held under. Without a channel nothing is measured.
    def place(visitor_id, channel)
      return ["no_channel", nil, nil] unless channel
      return ["held", nil, "project"] if project_control.positive? && Experiments::Bucket.of(@campaign.project.hashid, visitor_id) < project_control

      group = Experiments::Split.group(Experiments::Bucket.of(@campaign.hashid, visitor_id), control: @campaign.control_group.to_i,
                                                                                            variants: @campaign.variant_ids.size)
      return ["held", nil, "campaign"] if group == Experiments::Split::CONTROL

      waiting = @campaign.test_share && Experiments::Bucket.of("#{@campaign.hashid}:test", visitor_id) >= @campaign.test_share
      [waiting ? "waiting" : "pending", group, nil]
    end

    # A push sent from the API is transactional; the project-wide control group is for campaigns.
    def project_control
      @project_control ||= @campaign.source == "dashboard" ? InAppSetting.for(@campaign.project).control_group : 0
    end

    def not_found(recipients)
      return if recipients.empty?

      rows = recipients.uniq.map { |r| { push_campaign_id: @campaign.id, recipient: r, status: "not_found", created_at: @now, updated_at: @now } }
      PushDelivery.insert_all(rows)
    end

    def totals
      counts = @campaign.deliveries.group(:status).count
      { targeted: counts.sum { |status, n| %w[not_found held].include?(status) ? 0 : n },
        no_channel: counts.fetch("no_channel", 0), not_found: counts.fetch("not_found", 0),
        held: counts.fetch("held", 0), waiting: counts.fetch("waiting", 0) }
    end
  end
end
