class LinkOpenOrchestrationService
  class << self
    # Returns :quota_exceeded or :ok
    def call(project:, device:, link:, request:, go_to_fallback:, grovs_redirect:)
      return :quota_exceeded if project.instance.quota_exceeded

      if LinkDisplayService.should_log_view?(go_to_fallback, device, grovs_redirect)
        EventIngestionService.log_async(Grovs::Events::VIEW, project, device, nil, link)
      end

      ActionsService.create_if_needed(device, link)
      FingerprintingService.cache_device(device, request, project.id)

      :ok
    end
  end
end
