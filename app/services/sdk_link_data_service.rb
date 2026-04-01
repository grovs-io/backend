class SdkLinkDataService
  def initialize(project:, device:, platform:)
    @project = project
    @device = device
    @platform = platform
  end

  # Called when no link URL/path is provided — resolve via fingerprint match only.
  # Returns { data: ...|nil, link: ...|nil, tracking: ...|nil }
  def resolve_by_fingerprint(request, user_agent)
    matched_device = DeviceService.match_device_by_fingerprint_request(request, user_agent, @project, @device)
    return nil_result unless matched_device

    DeviceService.merge_visitor_events_and_device(matched_device, @device, @project)
    matched_action = ActionsService.action_for_device(matched_device)
    return nil_result unless matched_action

    ActionsService.mark_actions_before_action_as_handled(matched_action)
    link = matched_action.link

    return nil_result unless link.should_open_app_on_platform?(@platform)
    return nil_result if link.domain.project.id != @project.id

    data = matched_action.handled ? nil : link.data
    EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, link) unless matched_action.handled

    { data: data, link: link.access_path, tracking: link.tracking_dictionary }
  end

  # Called when a link URL/path is provided.
  # Falls back to resolve_by_fingerprint when link is nil.
  # Returns { data: ...|nil, link: ...|nil, tracking: ...|nil }
  def resolve_for_link(link, request, user_agent)
    return resolve_by_fingerprint(request, user_agent) unless link
    return nil_result if link.domain.project.id != @project.id

    link_url = link.access_path
    data = link.data
    matched_device = DeviceService.match_device_by_fingerprint_request(request, user_agent, @project, @device)
    action = nil

    if matched_device
      action = link.action_for(matched_device)
      DeviceService.merge_visitor_events_and_device(matched_device, @device, @project)
    end

    ActionsService.mark_actions_before_action_as_handled(action) if action
    EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, link) if !action || !action.handled

    { data: data, link: link_url, tracking: link.tracking_dictionary }
  end

  private

  def nil_result
    { data: nil, link: nil, tracking: nil }
  end
end
