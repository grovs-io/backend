class IosServerApiKeySerializer < BaseSerializer
  attributes :key_id, :issuer_id, :filename, :created_at


  def build(**)
    h = super()
    h["configured"] = record.private_key.present?
    h
  end
end
