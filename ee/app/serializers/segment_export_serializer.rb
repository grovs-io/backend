class SegmentExportSerializer < BaseSerializer
  attributes :status, :rows, :definition_hash, :error, :created_at, :updated_at

  def build(with_url: false, **)
    h = super()
    h["id"] = record.hashid
    h["segment_id"] = record.segment.hashid
    h["download_url"] = with_url ? record.download_url : nil
    h
  end
end
