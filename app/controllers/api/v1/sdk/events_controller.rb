class Api::V1::Sdk::EventsController < Api::V1::Sdk::BaseController
  # wrap_parameters nests the JSON body under an :event key, polluting params with
  # a duplicate wrapper that breaks the strict request contract. The SDK API is
  # flat JSON — read params directly.
  wrap_parameters false

  MAX_BATCH_SIZE = 50

  # Late events are legitimate (offline devices); future ones never are. Tolerance keeps benign
  # clock drift byte-identical so its event_id still dedups a replay.
  FUTURE_TOLERANCE = 2.minutes

  def add_batch
    raw_events = params[:events]
    unless raw_events.is_a?(Array)
      return render json: { error: "events must be an array" }, status: :bad_request
    end

    if raw_events.empty?
      return render json: { error: "events must not be empty" }, status: :bad_request
    end

    if raw_events.size > MAX_BATCH_SIZE
      return render json: { error: "max #{MAX_BATCH_SIZE} events per batch" }, status: :bad_request
    end

    accepted = 0
    errors = []

    seen_sdk_ids = Set.new
    payloads = raw_events.each_with_index.filter_map do |raw_event, index|
      result = build_event_payload(raw_event, index)
      if result[:error]
        errors << { index: index, error: result[:error] }
        next
      end
      # Only a repeated CLIENT id is a duplicate the client asked us to collapse. Never dedup on the
      # content hash: SDKs that send no id would have distinct events rejected, and JS drops those.
      if result[:sdk_event_id] && !seen_sdk_ids.add?(result[:sdk_event_id])
        errors << { index: index, error: "duplicate event_id in batch" }
        next
      end
      accepted += 1
      result[:payload]
    end

    EventIngestionService.enqueue_events(payloads) if payloads.any?

    render json: { accepted: accepted, rejected: errors.size, errors: errors }
  end

  def add_event
    parsed_created_at = parse_created_at(link_details_params[:created_at])

    # System events only: data/event_name belong to add_custom_event.
    EventIngestionService.log_async(
        link_details_params[:event],
        @project,
        @device,
        nil,
        resolve_link(event_type: link_details_params[:event]),
        link_details_params[:engagement_time],
        created_at: parsed_created_at,
        session_id: enrichment_params[:session_id],
        tags: enrichment_params[:tags]
    )

    render json: {message: "Event added"}, status: :ok
  end

  def add_custom_event
    event_name = enrichment_params[:event_name]
    return render json: { error: "event_name is required" }, status: :bad_request if event_name.blank?

    if Grovs::Events::RESERVED_EVENT_NAMES.include?(event_name)
      return render json: { error: "event_name is reserved" }, status: :bad_request
    end

    event_type = event_name == Grovs::Events::SCREEN_VIEW ? Grovs::Events::SCREEN_VIEW : Grovs::Events::CUSTOM

    EventIngestionService.log_async(
      event_type,
      @project,
      @device,
      enrichment_params[:properties],
      resolve_link,
      enrichment_params[:engagement_time],
      event_name: event_name,
      session_id: enrichment_params[:session_id],
      tags: enrichment_params[:tags]
    )

    render json: { message: "Event added" }, status: :ok
  end

  private

  MIGRATION_FALLBACK_EVENTS = [Grovs::Events::INSTALL, Grovs::Events::REINSTALL].freeze
  MIGRATION_FALLBACKS_PER_REQUEST = 3

  def resolve_link(event_type: nil)
    link_to_log = nil

    if link_param.present?
      link = LinksService.link_for_url(link_param, @project)
      link_to_log = link if link
    end

    if optional_path_param.present?
      link = LinksService.link_for_project_and_path(@project, optional_path_param)
      link_to_log = link if link
    end

    link_to_log || migration_fallback_link(link_param, event_type)
  rescue StandardError => e
    Rails.logger.warn("Sdk::EventsController link resolution failed, logging without link: #{e.message}")
    nil
  end

  # Installs carrying an old-host URL would otherwise land unattributed; OPENs resolve elsewhere.
  def migration_fallback_link(url, event_type)
    return nil unless url.present? && MIGRATION_FALLBACK_EVENTS.include?(event_type)
    raw = url.to_s
    # URLs and install referrers only — the bare-slug shape would upstream-resolve any garbage.
    return nil if !raw.match?(%r{\Ahttps?://}) && !raw.include?("=")
    # Cap per request: a crafted batch of uncached installs must not hold a thread 3s apiece.
    @migration_fallback_count = (@migration_fallback_count || 0) + 1
    return nil if @migration_fallback_count > MIGRATION_FALLBACKS_PER_REQUEST

    outcome = MigrationResolver.resolve_from_sdk(raw, expected_project: @project)
    outcome&.redirect? ? outcome.link : nil
  end

  def link_param
    params.permit(:link)[:link]
  end

  def optional_path_param
    params.permit(:path)[:path]
  end

  def link_details_params
    params.permit(:event, :created_at, :engagement_time)
  end

  def enrichment_params
    @enrichment_params ||= begin
      max_len = Grovs::Enrichment::MAX_STRING_LENGTH
      permitted = params.permit(:event_name, :session_id, :engagement_time, tags: [])
      permitted[:event_name] = permitted[:event_name].to_s.truncate(max_len, omission: "") if permitted[:event_name].present?
      permitted[:session_id] = permitted[:session_id].to_s.truncate(max_len, omission: "") if permitted[:session_id].present?
      permitted[:tags] = Array(permitted[:tags]).first(Grovs::Enrichment::MAX_TAGS).map { |t| t.to_s.truncate(max_len, omission: "") }
      permitted[:properties] = safe_properties
      permitted
    end
  end

  # Properties is a free-form key-value data bag — arbitrary keys are expected.
  # Strong parameters can't whitelist unknown keys, so we extract and sanitize
  # manually. Byte-size is capped to prevent oversized payloads flowing into
  # Redis, PG, and CH unchecked.
  def safe_properties
    raw = params[:properties]
    return nil unless raw.is_a?(ActionController::Parameters)

    hash = raw.to_unsafe_h
    return nil unless hash.is_a?(Hash)
    if hash.to_json.bytesize > Grovs::Enrichment::MAX_PROPERTIES_BYTES
      Rails.logger.warn("EventsController: properties exceeded #{Grovs::Enrichment::MAX_PROPERTIES_BYTES} bytes, dropped")
      return nil
    end

    hash
  end

  # --- Batch helpers ---

  # Validates and builds a single Redis payload hash from a raw batch event.
  # Returns {payload: Hash} on success or {error: String} on validation failure.
  def build_event_payload(raw, _index)
    ev = raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new(raw.to_h)

    # Counted here, not in frozen_ch_fields: only this endpoint can receive a client id, so
    # server-generated events must stay out of the ratio the rollout reads.
    sdk_event_id = ClickhouseWriteService.normalize_sdk_event_id(ev[:event_id])
    Grovs::Metrics.increment(sdk_event_id ? "events.event_id.sdk" : "events.event_id.fallback")

    result = if ev[:event].present?
               build_system_event_payload(ev)
             elsif ev[:event_name].present?
               build_custom_event_payload(ev)
             else
               { error: "missing event or event_name" }
             end
    result[:error] ? result : result.merge(sdk_event_id: sdk_event_id)
  rescue StandardError => e
    Rails.logger.warn("EventsController#build_event_payload error: #{e.message}")
    { error: "invalid event" }
  end

  # System event types the SDK may send via the `event` field.
  # CUSTOM and SCREEN_VIEW are routed through `event_name` instead.
  VALID_SYSTEM_EVENT_TYPES = (Grovs::Events::ALL - [Grovs::Events::CUSTOM, Grovs::Events::SCREEN_VIEW]).to_set.freeze

  def build_system_event_payload(raw_event)
    event_type = raw_event[:event].to_s
    return { error: "unknown event type '#{event_type}'" } unless VALID_SYSTEM_EVENT_TYPES.include?(event_type)

    max_len = Grovs::Enrichment::MAX_STRING_LENGTH

    parsed_created_at = parse_created_at(raw_event[:created_at])
    created_at_time = parsed_created_at || Time.current
    timestamp = created_at_time.iso8601(3)
    link = resolve_link_from_event(raw_event, event_type: event_type)
    tags = sanitize_tags(raw_event[:tags])
    session_id = raw_event[:session_id].to_s.truncate(max_len, omission: "")

    payload = {
      type: event_type,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: link&.id,
      engagement_time: raw_event[:engagement_time],
      created_at: timestamp,
      event_name: "",
      session_id: session_id,
      tags: tags
    }.merge(
      EventIngestionService.frozen_ch_fields(event_type, @project.id, @device.id, link, created_at_time, "", session_id,
                                              raw_event[:engagement_time], nil, sdk_event_id: raw_event[:event_id])
    )

    { payload: payload }
  end

  def build_custom_event_payload(raw_event)
    max_len = Grovs::Enrichment::MAX_STRING_LENGTH
    event_name = raw_event[:event_name].to_s.truncate(max_len, omission: "")

    return { error: "event_name '#{event_name}' is reserved" } if Grovs::Events::RESERVED_EVENT_NAMES.include?(event_name)

    event_type = event_name == Grovs::Events::SCREEN_VIEW ? Grovs::Events::SCREEN_VIEW : Grovs::Events::CUSTOM

    properties = extract_properties(raw_event[:properties])
    parsed_created_at = parse_created_at(raw_event[:created_at])
    created_at_time = parsed_created_at || Time.current
    timestamp = created_at_time.iso8601(3)
    link = resolve_link_from_event(raw_event)
    tags = sanitize_tags(raw_event[:tags])
    session_id = raw_event[:session_id].to_s.truncate(max_len, omission: "")

    payload = {
      type: event_type,
      project_id: @project.id,
      device_id: @device.id,
      data: properties,
      link_id: link&.id,
      engagement_time: raw_event[:engagement_time],
      created_at: timestamp,
      event_name: event_name,
      session_id: session_id,
      tags: tags
    }.merge(
      EventIngestionService.frozen_ch_fields(event_type, @project.id, @device.id, link, created_at_time,
                                              event_name, session_id, raw_event[:engagement_time], properties,
                                              sdk_event_id: raw_event[:event_id])
    )

    { payload: payload }
  end

  # Must clamp HERE, before frozen_ch_fields hashes the instant — a later clamp would
  # leave the stored created_at and its event_id disagreeing.
  def parse_created_at(value)
    return nil if value.blank?

    clamp_future(Time.parse(value.to_s))
  rescue ArgumentError
    nil
  end

  def clamp_future(time)
    return time unless time > Time.current + FUTURE_TOLERANCE

    Grovs::Metrics.increment("events.created_at.clamped", tags: { platform: @platform.to_s })
    Time.current
  end

  def resolve_link_from_event(raw_event, event_type: nil)
    link = nil
    link = LinksService.link_for_url(raw_event[:link], @project) if raw_event[:link].present?
    link = LinksService.link_for_project_and_path(@project, raw_event[:path]) || link if raw_event[:path].present?
    link || migration_fallback_link(raw_event[:link], event_type)
  rescue StandardError => e
    Rails.logger.warn("EventsController batch link resolution failed: #{e.message}")
    nil
  end

  def sanitize_tags(raw_tags)
    max_len = Grovs::Enrichment::MAX_STRING_LENGTH
    Array(raw_tags).first(Grovs::Enrichment::MAX_TAGS).map { |t| t.to_s.truncate(max_len, omission: "") }
  end

  def extract_properties(raw)
    return nil if raw.blank?

    hash = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw.to_h
    return nil unless hash.is_a?(Hash)

    if hash.to_json.bytesize > Grovs::Enrichment::MAX_PROPERTIES_BYTES
      Rails.logger.warn("EventsController: batch event properties exceeded #{Grovs::Enrichment::MAX_PROPERTIES_BYTES} bytes, dropped")
      return nil
    end

    hash
  end
end
