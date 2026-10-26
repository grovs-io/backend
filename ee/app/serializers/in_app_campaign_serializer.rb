class InAppCampaignSerializer < BaseSerializer
  attributes :name, :status, :revision, :template, :content, :triggers, :conditions, :caps, :schedule, :priority, :delay_seconds,
             :start_at, :end_at, :launched_at, :ended_at, :failure_reason, :created_at, :updated_at, :lock_version,
             :control_group, :conversion, :variants

  # The list leaves html out: a page of 200 could otherwise carry megabytes no list row shows.
  def build(list: false, **)
    h = super()
    h["id"] = record.hashid
    strip_html(h) if list
    h["audience"] = { "type" => record.audience_type, "segment_id" => record.segment&.hashid,
                      "segment_definition_hash" => record.segment_definition_hash, "segment_changed" => segment_changed? }
    h
  end

  private

  def strip_html(row)
    row["content"] = row["content"].except("html") if row["content"].is_a?(Hash)
    return unless row["variants"].is_a?(Array)

    row["variants"] = row["variants"].map { |v| v.is_a?(Hash) && v["content"].is_a?(Hash) ? v.merge("content" => v["content"].except("html")) : v }
  end

  # True when the segment was edited after launch, so the dashboard can offer to update the audience.
  def segment_changed?
    segment = record.segment
    return false if segment.nil? || record.segment_key.nil?

    segment.definition_hash != record.segment_definition_hash || segment.identifier_list_generation != record.segment_list_generation
  end
end
