class InstalledApp < ApplicationRecord
  include ModelCachingExtension

  belongs_to :device
  belongs_to :project

  def self.fetch_for_device_and_project(device_id, project_id)
    redis_find_by_multiple_conditions({ device_id: device_id, project_id: project_id })
  end

  def cache_keys_to_clear
    keys = super
    if device_id && project_id
      keys << multi_condition_cache_key({ device_id: device_id, project_id: project_id })
    end
    keys
  end
end
