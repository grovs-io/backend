class EventSerializer < BaseSerializer
  attributes :id, :event, :path, :platform, :ip, :remote_ip,
             :app_version, :build, :data, :engagement_time,
             :vendor_id, :processed, :created_at, :updated_at
end
