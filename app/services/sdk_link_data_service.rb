class SdkLinkDataService
  def initialize(project:, device:, platform:, session_id: nil)
    @project = project
    @device = device
    @platform = platform
    @session_id = session_id
  end

  # Called when no link URL/path is provided — resolve via fingerprint match only.
  # Returns { data: ...|nil, link: ...|nil, tracking: ...|nil }
  def resolve_by_fingerprint(request, user_agent)
    matched_device = DeviceService.match_device_by_fingerprint_request(request, user_agent, @project, @device)
    return nil_result unless matched_device

    matched_action = ActionsService.action_for_device(matched_device)
    action_ids = ActionsService.action_ids_before_action(matched_action) if matched_action
    DeviceService.merge_visitor_events_and_device(matched_device, @device, @project)
    return nil_result unless matched_action

    ActionsService.mark_actions_before_action_as_handled(matched_action, action_ids: action_ids)
    link = matched_action.link

    return nil_result unless link.should_open_app_on_platform?(@platform)
    return nil_result if link.domain.project.id != @project.id

    data = matched_action.handled ? nil : link.data
    unless matched_action.handled
      EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, link, session_id: @session_id)
    end

    { data: data, link: link.access_path, tracking: link.tracking_dictionary }
  end

  # Called when a link URL/path is provided.
  # Falls back to resolve_by_fingerprint when link is nil.
  # Returns { data: ...|nil, link: ...|nil, tracking: ...|nil }
  def resolve_for_link(link, request, user_agent, raw_url: nil, from_push: false)
    # A push tap is counted as push_open alone, so it neither opens the link nor matches devices.
    return nil_result if from_push && !link
    return resolve_by_fingerprint(request, user_agent) unless link
    return nil_result if link.domain.project.id != @project.id

    link_url = link.access_path
    data = link.data
    return { data: data, link: link_url, tracking: link.tracking_dictionary } if from_push

    matched_device, action = clipboard_match(link, raw_url)
    if matched_device
      Grovs::Metrics.increment("links.clipboard_match")
    else
      matched_device = DeviceService.match_device_by_fingerprint_request(request, user_agent, @project, @device)
      action = link.action_for(matched_device) if matched_device
    end

    # Capture IDs before a merge can change the device used to find these actions.
    action_ids = ActionsService.action_ids_before_action(action) if action
    DeviceService.merge_visitor_events_and_device(matched_device, @device, @project) if matched_device

    ActionsService.mark_actions_before_action_as_handled(action, action_ids: action_ids) if action
    if !action || !action.handled
      EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, link, session_id: @session_id)
    end

    { data: data, link: link_url, tracking: link.tracking_dictionary }
  end

  private

  # gd counts only with a 48h Action on this link — forgery guard, wider than fingerprint's 5min.
  def clipboard_match(link, raw_url)
    return nil if raw_url.blank?

    gd = URI.decode_www_form(URI.parse(raw_url).query || '').to_h['gd']
    return nil if gd.blank?

    device = Device.find_by_hashid(gd)
    return nil unless device

    action = link.action_for(device, within: Grovs::Links::CLIPBOARD_VALIDITY)
    return nil unless action

    [device, action]
  rescue StandardError
    nil
  end

  def nil_result
    { data: nil, link: nil, tracking: nil }
  end
end
