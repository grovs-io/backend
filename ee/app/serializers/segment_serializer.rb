class SegmentSerializer < BaseSerializer
  attributes :name, :description, :definition, :definition_hash, :archived, :created_at, :updated_at

  UNSET = Object.new.freeze

  # size: pass the preloaded snapshot for a batch to avoid an N+1; omit for a single record.
  def build(size: UNSET, **)
    h = super()
    h["id"] = record.hashid
    listed = record.identifier_list_generation.present?
    h["has_identifier_list"] = listed
    h["identifier_list"] = listed ? identifier_list : nil
    h["size"] = size.equal?(UNSET) ? latest_size : size
    h
  end

  private

  def identifier_list
    { "count" => record.identifier_list_count, "updated_at" => record.identifier_list_updated_at&.iso8601(3) }
  end

  def latest_size
    snap = record.size_snapshots.fresh.where(definition_hash: record.definition_hash).order(date: :desc).first
    snap && { "date" => snap.date.to_s, "persons" => snap.persons, "devices" => snap.devices }
  end
end
