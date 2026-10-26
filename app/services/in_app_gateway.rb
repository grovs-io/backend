# Core entry point for in-app messages; a no-op without ee/.
module InAppGateway
  EVENT_NAMES = (Grovs::Events::MESSAGE_EVENT_NAMES - [Grovs::Events::PUSH_OPEN]).to_set.freeze

  module_function

  def event?(name) = EVENT_NAMES.include?(name)

  def accept(project:, visitor:, name:, properties:, event_id:)
    return false unless defined?(InAppEventCheck)

    InAppEventCheck.accept(project: project, visitor: visitor, name: name, properties: properties, event_id: event_id)
  end

  OFF = { "campaigns_changed_at" => "off", "user_changed_at" => "off" }.freeze

  # Switched off, the stamps still go out and differ from any a device holds, so it syncs and empties itself.
  def stamps(project:, visitor:)
    return nil unless defined?(InAppStamps)
    return OFF unless Grovs.in_app_enabled? && project.instance.in_app_enabled?

    InAppStamps.for(project.id, visitor.id)
  end

  def identified(visitor, changed:)
    InAppViews.identified(visitor, changed: changed) if defined?(InAppViews) && Grovs.in_app_enabled?
  end

  def merge(from:, to:)
    return unless defined?(InAppViews) && defined?(InAppMemberships)

    InAppViews.merge(from: from, to: to)
    InAppMemberships.move(from: from, to: to)
  end
end
