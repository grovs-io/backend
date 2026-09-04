class Api::V1::Sdk::ScreenAliasesController < Api::V1::Sdk::BaseController
  # wrap_parameters nests the body under :screen_alias, breaking the strict
  # request contract. The SDK API is flat JSON — read params directly.
  wrap_parameters false

  MAX_ALIASES_PER_REQUEST = 200

  def create
    raw = params[:screen_aliases]
    return render json: { error: "screen_aliases must be an array" }, status: :bad_request unless raw.is_a?(Array)
    return render json: { error: "screen_aliases must not be empty" }, status: :bad_request if raw.empty?
    return render json: { error: "max #{MAX_ALIASES_PER_REQUEST} aliases per request" }, status: :bad_request if raw.size > MAX_ALIASES_PER_REQUEST

    now = Time.current
    rows_by_identifier = {}
    raw.each do |entry|
      next unless entry.is_a?(ActionController::Parameters) || entry.is_a?(Hash)

      identifier = entry[:identifier].to_s.strip.truncate(255, omission: "")
      alias_name = entry[:alias].to_s.strip.truncate(255, omission: "")
      next if identifier.blank? || alias_name.blank?

      rows_by_identifier[identifier] = {
        project_id: @project.id,
        screen_identifier: identifier,
        alias_name: alias_name,
        created_at: now,
        updated_at: now
      }
    end

    rows = rows_by_identifier.values
    if rows.any?
      ScreenAlias.upsert_all(
        rows,
        unique_by: [:project_id, :screen_identifier],
        update_only: [:alias_name]
      )
    end

    render json: { saved: rows.size }
  end
end
