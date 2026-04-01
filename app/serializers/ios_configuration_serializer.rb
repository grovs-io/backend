class IosConfigurationSerializer < BaseSerializer
  attributes :app_prefix, :bundle_id, :tablet_enabled


  def build(**)
    h = super()
    h["push_configuration"] = IosPushConfigurationSerializer.serialize(record.ios_push_configuration)
    h["server_api_key"] = IosServerApiKeySerializer.serialize(record.ios_server_api_key)
    h
  end
end
