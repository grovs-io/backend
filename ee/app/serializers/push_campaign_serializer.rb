class PushCampaignSerializer < BaseSerializer
  attributes :name, :title, :body, :image_url, :sound, :data, :source, :status, :scheduled_at, :local_time, :timezone,
             :evaluated_at, :started_at, :finished_at, :failure_reason, :created_at, :updated_at,
             :control_group, :conversion, :variants, :test_share, :winner_after_minutes, :winner_by, :winner_due_at, :winner

  # slim: list rows carry recipients_count only; up to 10k strings per campaign is a show-only payload.
  def build(slim: false, **)
    h = super()
    h["id"] = record.hashid
    h["link_id"] = record.link_id
    h["image"] = record.image_resource
    h["audience"] = { "type" => record.audience_type, "recipients_count" => record.recipients.size,
                      "segment_id" => record.segment&.hashid, "segment_definition_hash" => record.segment_definition_hash }
    h["audience"]["recipients"] = record.recipients unless slim
    h["report"] = record.report.deep_stringify_keys
    h
  end
end
