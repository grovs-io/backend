class ApplicationSerializer < BaseSerializer
  CONFIGURATION_SERIALIZERS = {
    "IosConfiguration" => IosConfigurationSerializer,
    "AndroidConfiguration" => AndroidConfigurationSerializer,
    "DesktopConfiguration" => DesktopConfigurationSerializer,
    "WebConfiguration" => WebConfigurationSerializer
  }.freeze

  attributes :instance_id, :platform, :enabled


  def build(**)
    h = super()
    config = record.configuration
    serializer = CONFIGURATION_SERIALIZERS[config.class.name] if config
    h["configuration"] = serializer ? serializer.serialize(config) : nil
    h
  end
end
