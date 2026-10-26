class Api::V1::SegmentsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  LIST_LIMIT = 200

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :load_segment, only: %i[show update destroy size_history identifier_list_preview identifier_list_download]
  before_action :load_active_segment, only: %i[count users breakdown export identifier_list]

  rescue_from Segments::ResultExpired do
    render json: { error: "This result has expired — reload the segment.", error_code: "result_expired" }, status: :gone
  end
  rescue_from Segments::Busy do
    render json: { error: "Too many segment queries are running; retry shortly.", error_code: "segment_busy" }, status: :too_many_requests
  end
  rescue_from Segments::WindowExpired do
    render json: { error: "A 'did not' condition covers dates older than your data retention.", error_code: "window_expired" },
           status: :unprocessable_entity
  end
  rescue_from Analytics::QueryTooHeavy do
    render json: { error: "Segment is too heavy — narrow a window or remove a condition.", error_code: "query_too_heavy" },
           status: :unprocessable_entity
  end
  rescue_from Segments::InvalidDefinition do |e|
    render json: { error: "Invalid segment definition: #{e.message}",
                   error_code: "invalid_definition" }, status: :unprocessable_entity
  end
  rescue_from Segments::UploadInProgress do
    render json: { error: "Another upload for this segment is still running.", error_code: "upload_in_progress" }, status: :conflict
  end
  rescue_from Segments::InvalidList do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def index
    archived = ActiveModel::Type::Boolean.new.cast(params[:archived]) || false
    list = @project.segments.where(archived: archived).order(updated_at: :desc).limit(LIST_LIMIT + 1).to_a
    truncated = list.size > LIST_LIMIT
    list = list.first(LIST_LIMIT)
    sizes = latest_sizes_for(list)
    render json: { segments: list.map { |s| SegmentSerializer.serialize(s, size: sizes[s.id]) }, truncated: truncated }, status: :ok
  end

  def fields = render json: Segments::Catalogue.for(@project), status: :ok

  def show = render_one(:ok)

  def size_history
    rows = @segment.size_snapshots.where(definition_hash: @segment.definition_hash).order(date: :desc).limit(180)
    render json: { size_history: rows.map { |r| { date: r.date.to_s, persons: r.persons, devices: r.devices, incomplete: r.incomplete } } },
           status: :ok
  end

  def create
    @segment = @project.segments.new(created_by: current_user)
    return unless assign
    return render_invalid unless @segment.save

    audit!("segment.created", instance_id: @project.instance_id, target: audit_target(@segment),
                             changes: { "after" => { "name" => @segment.name } })
    render_one(:created)
  end

  def update
    return unless assign
    return render_invalid unless @segment.save

    audit!("segment.updated", instance_id: @project.instance_id, target: audit_target(@segment))
    render_one(:ok)
  end

  def destroy
    @segment.update!(archived: true)
    audit!("segment.archived", instance_id: @project.instance_id, target: audit_target(@segment))
    render json: { message: "Segment archived" }, status: :ok
  end

  def estimate
    raise Clickhouse::Unavailable, "segments" unless Segments.available?

    target = estimate_target
    return if performed?

    list_from = draft_list_source
    return if performed?

    render json: Segments.estimate(@project, target, list_from: list_from, lane: segment_lane), status: :ok
  end

  def count
    m = Segments.result_for(@project, @segment, lane: segment_lane)
    render json: { persons: m.persons, devices: m.devices, incomplete: m.incomplete, result_id: m.result_id }, status: :ok
  end

  def identifier_list
    identifiers = params[:file].respond_to?(:read) ? Segments::IdentifierList.parse_csv(params[:file]) : params[:identifiers]
    out = Segments::IdentifierList.replace!(@segment, identifiers.is_a?(Array) ? identifiers : [])
    audit!("segment.identifier_list_replaced", instance_id: @project.instance_id, target: audit_target(@segment),
           changes: { "after" => { "count" => out[:count] } })
    render json: { segment: SegmentSerializer.serialize(@segment.reload), count: out[:count] }, status: :ok
  end

  def identifier_list_preview
    raise Clickhouse::Unavailable, "segments" unless Segments.available?

    render json: Segments::IdentifierList.preview(@segment, q: params[:q]), status: :ok
  end

  def identifier_list_download
    raise Clickhouse::Unavailable, "segments" unless Segments.available?
    return render(json: { error: "No identifier list" }, status: :not_found) if @segment.identifier_list_generation.blank?

    csv = Segments::IdentifierList.to_csv(@segment)
    audit!("segment.identifier_list_downloaded", instance_id: @project.instance_id, target: audit_target(@segment),
           changes: { "after" => { "count" => @segment.identifier_list_count } })
    response.headers["Cache-Control"] = "no-store"
    send_data csv, type: "text/csv", disposition: "attachment", filename: "segment_#{@segment.hashid}_identifiers.csv"
  end

  def breakdown
    manifest = params[:result_id].present? ? pinned_result(params[:result_id]) : Segments.result_for(@project, @segment, lane: segment_lane)
    render json: Segments::Breakdown.call(project: @project, manifest: manifest, by: params[:by], lane: segment_lane)
                                    .merge(result_id: manifest.result_id), status: :ok
  rescue ArgumentError
    render json: { error: "by must be one of #{Segments::Breakdown::DIMENSIONS.join(', ')} or properties.<key>" }, status: :unprocessable_entity
  end

  def users
    manifest, after, q = users_target
    page = Segments::Members.page(manifest: manifest, after: after, limit: params.fetch(:limit, 50), q: q)
    cursor = page[:next_after] && Segments::Members.encode_cursor(manifest.result_id, page[:next_after], q)
    render json: { users: page[:users], next_cursor: cursor, result_id: manifest.result_id,
                   persons: manifest.persons, devices: manifest.devices, incomplete: manifest.incomplete }, status: :ok
  rescue ArgumentError, TypeError
    render json: { error: "limit must be an integer" }, status: :unprocessable_entity
  end

  def export
    record = @project.segment_exports.create!(segment: @segment, user: current_user, definition: @segment.definition,
                                              definition_hash: @segment.definition_hash,
                                              identifier_list_generation: @segment.identifier_list_generation)
    SegmentExportJob.perform_async(record.id)
    audit!("segment.exported", instance_id: @project.instance_id, target: audit_target(@segment),
                              changes: { "after" => { "export_id" => record.hashid } })
    render json: { export: SegmentExportSerializer.serialize(record) }, status: :accepted
  end

  def exports
    list = @project.segment_exports.includes(:segment).order(created_at: :desc).limit(50)
    render json: { exports: list.map { |e| SegmentExportSerializer.serialize(e) } }, status: :ok
  end

  def export_status
    record = @project.segment_exports.find_by_hashid(params[:export_id])
    return render(json: { error: "Export not found" }, status: :not_found) unless record

    ActiveStorage::Current.url_options = { host: request.base_url }
    render json: { export: SegmentExportSerializer.serialize(record, with_url: true) }, status: :ok
  end

  private

  def segment_lane = :dashboard

  def latest_sizes_for(segments)
    ids = segments.map(&:id)
    return {} if ids.empty?

    by_id = segments.index_by(&:id)
    SegmentSizeSnapshot.fresh.where(segment_id: ids).order(date: :desc).group_by(&:segment_id).each_with_object({}) do |(id, snaps), out|
      snap = snaps.find { |s| s.definition_hash == by_id[id].definition_hash }
      out[id] = snap && { "date" => snap.date.to_s, "persons" => snap.persons, "devices" => snap.devices }
    end
  end

  # A first page may pin the result the page already holds (from count), so a stale reuse key never rebuilds.
  def users_target
    q = params[:q].presence
    return [pinned_result(params[:result_id]), 0, q] if params[:cursor].blank? && params[:result_id].present?
    return [Segments.result_for(@project, @segment), 0, q] if params[:cursor].blank?

    result_id, after, cursor_q = Segments::Members.decode_cursor(params[:cursor])
    [pinned_result(result_id), after, cursor_q.presence]
  end

  # A list generation is random per segment upload, so it pins the segment too.
  def pinned_result(result_id)
    manifest = Segments::Results.fetch!(@project.id, result_id)
    raise Segments::ResultExpired, "result belongs to another definition" unless manifest.definition_hash == @segment.definition_hash
    raise Segments::ResultExpired, "result belongs to another list" unless manifest.list_generation.to_s == @segment.identifier_list_generation.to_s

    manifest
  end

  def load_active_segment
    @segment = @project.segments.active.find_by_hashid(params[:segment_id])
    render json: { error: "Segment not found" }, status: :not_found unless @segment
  end

  # A draft sent with a segment_id is an edit of that segment: its identifier list backs the draft's in_list.
  def draft_list_source
    return nil if params[:definition].blank? || params[:segment_id].blank?

    segment = @project.segments.active.find_by_hashid(params[:segment_id])
    render json: { error: "Segment not found" }, status: :not_found unless segment
    segment
  end

  def estimate_target
    if params[:segment_id].present? && params[:definition].blank?
      segment = @project.segments.active.find_by_hashid(params[:segment_id])
      return segment if segment

      render json: { error: "Segment not found" }, status: :not_found
      return nil
    end
    parsed = Segments::Definition.parse(params[:definition], cutoff_date: retention_cutoff)
    return parsed if parsed.valid?

    render json: { error: parsed.errors.map { |e| "#{e[:path]}: #{e[:message]}" }.join(", ") }, status: :unprocessable_entity
    nil
  end

  def retention_cutoff = Analytics::RetentionPolicy.for(@project.instance).queryable_cutoff_date

  def assign
    @segment.name = params[:name] if params.key?(:name)
    @segment.description = params[:description] if params.key?(:description)
    @segment.archived = ActiveModel::Type::Boolean.new.cast(params[:archived]) if params.key?(:archived)
    return true unless params.key?(:definition)

    unless params[:definition].respond_to?(:to_unsafe_h)
      render json: { error: "definition must be an object" }, status: :unprocessable_entity
      return false
    end
    @segment.definition = params[:definition].to_unsafe_h
    true
  end

  def render_one(status) = render(json: { segment: SegmentSerializer.serialize(@segment) }, status: status)

  def render_invalid
    render json: { error: @segment.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def load_segment
    @segment = @project.segments.find_by_hashid(params[:segment_id])
    render json: { error: "Segment not found" }, status: :not_found unless @segment
  end
end
