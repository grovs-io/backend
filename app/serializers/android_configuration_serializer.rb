class AndroidConfigurationSerializer < BaseSerializer
  attributes :identifier, :sha256s, :tablet_enabled


  def build(**)
    h = super()
    h["push_configuration"] = AndroidPushConfigurationSerializer.serialize(record.android_push_configuration)
    h["server_api_key"] = AndroidServerApiKeySerializer.serialize(record.android_server_api_key)
    h
  end
end
