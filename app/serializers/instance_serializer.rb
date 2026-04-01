class InstanceSerializer < BaseSerializer
  attributes :id, :api_key, :uri_scheme, :updated_at,
             :get_started_dismissed, :quota_exceeded,
             :revenue_collection_enabled


  def build(**)
    h = super()
    h["production"] = ProjectSerializer.serialize(record.production)
    h["test"] = ProjectSerializer.serialize(record.test)
    h["hash_id"] = record.hashid
    h
  end
end
