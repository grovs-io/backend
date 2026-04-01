class ActionsService

  class << self
    def create_if_needed(device, link)
      action = Action.find_by(device_id: device.id, link_id: link.id, handled: false)
      Rails.logger.debug("Action search")
      if !action || action.created_at < Grovs::Links::VALIDITY_MINUTES.minutes.ago
        Action.create(device_id: device.id, link_id: link.id, handled: false)
        Rails.logger.debug("Action created")
      end
      Rails.logger.debug("Action end")
    end

    def action_for_device(device)
      Action.where(device_id: device.id).where("created_at >= ?", Grovs::Links::VALIDITY_MINUTES.minutes.ago).order(created_at: :desc).first
    end

    def mark_actions_before_action_as_handled(old_action)
      actions = Action.where(device_id: old_action.device_id).where('created_at <= ?', old_action.created_at)

      # Mark all the actions as handled
      actions.each do |action|
        unless action.link
          action.destroy!  # This will destroy the action
          next
        end

        action.handled = true
        action.save!
      end
    end
  end

end
