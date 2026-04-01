class DeviceSerializer < BaseSerializer
  attributes :id, :platform, :model, :app_version, :build,
             :language, :timezone, :screen_width, :screen_height,
             :created_at, :updated_at
end
