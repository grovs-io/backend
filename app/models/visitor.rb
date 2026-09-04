class Visitor < ApplicationRecord
  include Hashid::Rails
  include ModelCachingExtension

  # First: a raise in an after_commit callback halts the rest of the chain.
  after_create_commit :stamp_device_last_seen
  after_create_commit :add_notifications_if_needed

  belongs_to :project
  belongs_to :device

  scope :for_project, ->(project_id) { where(project_id: project_id) }

  has_many :links
  has_many :events, through: :links
  has_many :notifications
  has_many :notification_messages, dependent: :destroy

  # A visitor can invite many other visitors
  has_many :invited_visitors, class_name: "Visitor", foreign_key: "inviter_id", dependent: :nullify

  # A visitor can be invited by another visitor
  belongs_to :inviter, class_name: "Visitor", optional: true
  has_many :visitor_daily_statistics, dependent: :destroy
  has_many :referral_daily_statistics,
           class_name: "VisitorDailyStatistic",
           foreign_key: :invited_by_id,
           dependent: :nullify,
           inverse_of: false
  has_many :visitor_last_visits, dependent: :delete_all

  def self.fetch_by_hash_id(linkedsquared_id, project_id)
    return nil if project_id.nil?

    decoded_id = Visitor.decode_id(linkedsquared_id)
    Visitor.redis_find_by_multiple_conditions({id: decoded_id, project_id: project_id}, includes: [:device])
  end

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:id:#{id}:includes:device" if id
    if id && project_id
      keys << multi_condition_cache_key({id: id, project_id: project_id}, includes: [:device])
    end
    if device_id && project_id
      keys << multi_condition_cache_key({device_id: device_id, project_id: project_id}, includes: [:device])
      keys << multi_condition_cache_key({device_id: device_id, project_id: project_id})
    end
    # Clear old device_id keys if device_id changed (e.g. during visitor merge)
    if previous_changes.key?('device_id') && previous_changes['device_id'][0].present? && project_id
      old_device_id = previous_changes['device_id'][0]
      keys << multi_condition_cache_key({device_id: old_device_id, project_id: project_id}, includes: [:device])
      keys << multi_condition_cache_key({device_id: old_device_id, project_id: project_id})
    end
    keys
  end

  def add_notifications_if_needed
    NotificationMessageService.add_messages_for_new_visitor(self)
  end

  # Visitor is the (project, device) grain: stamping here is what makes device_last_seens complete.
  def stamp_device_last_seen
    DeviceLastSeen.stamp_batch!({ [project_id, device_id] => Time.current })
  rescue StandardError => e
    Grovs::Metrics.increment("device_last_seen.stamp_failed", tags: { source: "visitor_create" })
    Rails.logger.warn("Visitor#stamp_device_last_seen failed for #{project_id}/#{device_id}: #{e.class}: #{e.message}")
  end
end
