# What one visitor's device should hold. Postgres and Redis only; never ClickHouse.
class InAppSync
  CACHE = 5.minutes

  STORE_CACHE = 10.minutes

  def self.call(project:, visitor:, held:, platform: nil, device: nil)
    new(project, visitor, held, platform, device).call
  end

  def initialize(project, visitor, held, platform, device)
    @project = project
    @visitor = visitor
    @held = held
    @platform = platform
    @device = device
  end

  def call
    now = InAppDefinition.stamp(Time.current)
    return off(now) unless Grovs.in_app_enabled? && @project.instance.in_app_enabled?

    stamps = InAppStamps.for(@project.id, @visitor.id)
    if stamps && stamps == @held
      hold_again(stamps)
      return { "unchanged" => true, "server_time" => now, "store_url" => store_url }
    end

    served = served_campaigns(stamps)
    @served_control = served["control"]
    (stamps || {}).merge("server_time" => now, "store_url" => store_url, "first_seen_at" => InAppDefinition.stamp(@visitor.created_at),
                         "global_caps" => served["caps"], "campaigns" => mine(served["campaigns"]), "test_messages" => InAppTests.take(@visitor.id))
  end

  private

  def off(now)
    { "campaigns_changed_at" => "off", "user_changed_at" => "off", "server_time" => now, "store_url" => nil, "first_seen_at" => nil,
      "global_caps" => { "session" => InAppSetting::DEFAULT_CAP, "day" => InAppSetting::DEFAULT_CAP }, "campaigns" => [], "test_messages" => [] }
  end

  # Where an "open the store" button leads on this platform; nil until the store has told us, and on the web.
  def store_url
    return nil unless [Grovs::Platforms::ANDROID, Grovs::Platforms::IOS].include?(@platform)

    # "" stands for "none", so a project with no store page is not looked up at every sync.
    Rails.cache.fetch("in_app:store_url:#{@project.id}:#{@platform}", expires_in: STORE_CACHE) { find_store_url.to_s }.presence
  rescue StandardError => e
    Rails.logger.warn("in_app.store_url_failed #{e.class}")
    nil
  end

  def find_store_url
    config = @project.instance.application_for_platform(@platform)&.configuration
    if @platform == Grovs::Platforms::ANDROID
      return config&.identifier.presence && "https://play.google.com/store/apps/details?id=#{config.identifier}"
    end

    id = config&.bundle_id.presence && AppstoreService.fetch_image_and_title_for_identifier(config.bundle_id)[:appstore_id].presence
    id && "https://apps.apple.com/app/id#{id}"
  end

  # Keyed by the stamp, so any change to a campaign or to the settings leaves the old entry behind.
  def served_campaigns(stamps)
    return load_served if stamps.nil?

    Rails.cache.fetch("in_app:served:#{@project.id}:#{stamps['campaigns_changed_at']}", expires_in: CACHE) { load_served }
  rescue Redis::BaseError
    load_served
  end

  def load_served
    setting = InAppSetting.for(@project)
    rows = setting.enabled ? @project.in_app_campaigns.served.order(:id).to_a : []
    { "caps" => { "session" => setting.session_cap, "day" => setting.day_cap }, "control" => setting.control_group,
      "campaigns" => rows.map do |c|
        { "row" => c.id, "id" => c.hashid, "segment_key" => c.segment_key, "end_at" => c.end_at&.to_f, "lifetime" => c.caps["lifetime"],
          "asks" => c.contents.any? { |content| content["question"].present? }, "definition" => c.definition,
          "split" => c.experiment? && { "control" => c.control_group.to_i, "variants" => c.variant_ids.size },
          "variants" => c.variant_ids.drop(1).index_with { |id| c.definition_for(id) } }
      end }
  end

  def mine(campaigns)
    open = campaigns.reject { |c| c["end_at"] && c["end_at"] <= Time.current.to_f }
    return [] if open.empty?
    return project_held if held_from_all?

    keys = open.any? { |c| c["segment_key"] } ? SegmentMembership.where(visitor_id: @visitor.id).pluck(:segment_key).to_set : Set.new
    seen = open.any? { |c| c["lifetime"] || c["asks"] } ? InAppViews.seen(project_id: @project.id, visitor: @visitor) : {}
    open.select { |c| c["segment_key"].nil? || keys.include?(c["segment_key"]) }
        .reject { |c| c["lifetime"] && seen.dig(c["row"], :total).to_i >= c["lifetime"] }
        .reject { |c| c["asks"] && seen.dig(c["row"], :answered) }
        .filter_map { |c| pick(c) }
  end

  # A held person syncs as unchanged for days; their daily hold is still recorded so the control keeps its size.
  # Only the small per-stamp list of controls is read, and the day's Redis mark is checked before any query.
  def hold_again(stamps)
    controls = control_list(stamps)
    @served_control = controls["control"]
    return if controls["served"].zero?
    return project_held if held_from_all? && Experiments::Held.pending?(@project, @visitor)

    held = controls["campaigns"].select do |c|
      Experiments::Bucket.of(c["id"], @visitor.id) < c["split"]["control"] && Experiments::Held.pending?(@project, @visitor, campaign: c["id"])
    end
    return if held.empty?

    mine(held)
    # Outside the audience today: marked as checked, so the segment is not asked again until tomorrow.
    held.each { |c| Experiments::Held.mark(@project, @visitor, campaign: c["id"]) }
  rescue StandardError => e
    Rails.logger.warn("in_app.hold_again_failed #{e.class}")
  end

  # Only what a hold needs, so the busiest path never decodes the definitions.
  def control_list(stamps)
    Rails.cache.fetch("in_app:controls:#{@project.id}:#{stamps['campaigns_changed_at']}", expires_in: CACHE) do
      served = served_campaigns(stamps)
      { "control" => served["control"], "served" => served["campaigns"].size,
        "campaigns" => served["campaigns"].select { |c| c["split"] && c["split"]["control"].positive? }
                                          .map { |c| c.slice("row", "id", "segment_key", "end_at", "lifetime", "asks", "split") } }
    end
  end

  # The served list is read from the cache, so the control percent rides on it and changes with the stamp.
  def held_from_all?
    pct = @served_control.to_i
    pct.positive? && Experiments::Bucket.of(@project.hashid, @visitor.id) < pct
  end

  def project_held
    Experiments::Held.in_app(project: @project, device: @device, visitor: @visitor)
    []
  end

  # The person's group is fixed by the bucket; the control gets nothing and is counted, the rest get their variant.
  def pick(campaign)
    split = campaign["split"]
    return campaign["definition"] unless split

    group = Experiments::Split.group(Experiments::Bucket.of(campaign["id"], @visitor.id), control: split["control"], variants: split["variants"])
    return campaign["variants"][group] || campaign["definition"] unless group == Experiments::Split::CONTROL

    Experiments::Held.in_app(project: @project, device: @device, visitor: @visitor, campaign: campaign["id"])
    nil
  end
end
