class Public::LinksController < Public::BaseController
  def open_app_link
    link = LinksService.link_for_request(request)
    unless link
      # Migrate-from-competitors tail fallback: if this is an old-host click (and
      # MIGRATIONS_ENABLED is on), the resolver returns either a 301 to a freshly-materialized
      # Link OR a project_defaults outcome. Web entry omits expected_project — the host alone
      # determines which source/project owns this click.
      migration_outcome = MigrationResolver.resolve(
        request.host,
        request.path[1..].to_s,
        query_string: request.query_string
      )
      if migration_outcome
        Grovs::Metrics.increment("migration.outcome",
          tags: { kind: migration_outcome.kind.to_s, provider: migration_outcome.provider })
        return execute_migration_outcome(migration_outcome)
      end
      render_not_found
      return
    end

    @project = link.domain.project
    @device = DeviceService.device_for_website_visit(request, response, @project)

    result = LinkOpenOrchestrationService.call(
      project: @project, device: @device, link: link,
      request: request, go_to_fallback: go_to_fallback_param,
      grovs_redirect: grovs_redirect
    )

    if result == :quota_exceeded
      render_quota_exceeded
      return
    end

    assign_generic_data(link)

    decision = PlatformRenderDecisionService.call(
      device: @device, link: link, project: @project,
      go_to_fallback: go_to_fallback_param
    )

    execute_render_decision(decision)
  end

  def make_redirect
    link = LinksService.link_for_redirect_url(url_param)
    unless link
      render_not_found
      return
    end

    @name = nil
    @image = nil
    @project = link&.domain&.project

    @device = DeviceService.device_for_website_visit(request, response, @project)

    # The preview host's cookie device can carry a stale platform; this render is about the live browser.
    live_platform = @device.user_agent_platform

    if @project
      name_and_image = WebConfigurationService.name_and_image_for_project_and_platform(@project, live_platform)
      @name, @image = name_and_image.values_at(:name, :image)
    end

    @redirect_url = LinksService.build_redirect_url_for_preview(url_param, link, @device)
    @copy_payload = link.copy_to_clipboard_for?(live_platform) ? url_param : nil
    @skip_client_data = true
    assign_generic_data(link)

    render template: "public/display/redirect", formats: [:html]
  rescue StandardError => e
    cookie = request.cookies["LINKSQUARED"]
    Rails.logger.error(
      "[make_redirect] #{e.class}: #{e.message} " \
      "| url=#{url_param} " \
      "| project=#{@project&.id} " \
      "| link=#{link&.id} " \
      "| cookie=#{cookie.present?} " \
      "| ua=#{request.user_agent} " \
      "| backtrace=#{e.backtrace&.first(15)&.join(' | ')}"
    )
    render_not_found unless performed?
  end

  private

  # Serve a MigrationOutcome from MigrationResolver. Web entry only — SDK callers read
  # outcome.link directly without rendering.
  def execute_migration_outcome(outcome)
    case outcome.kind
    when :redirect
      # 301 to the materialized Link (with original query string preserved). The browser
      # follows to <project_domain>/<new_slug>?... which runs the existing native orchestration
      # and records Event/Visitor/LinkDailyStatistic — see design §6.1 two-request analytics.
      redirect_to outcome.url, allow_other_host: true, status: :moved_permanently
    when :project_defaults
      # No link material; fall back to the project's redirect_config default_fallback. A
      # future enhancement could route per-platform, but the simple default covers the MVP
      # case where upstream said "not found" or errored — better than returning 404.
      default_url = outcome.project&.redirect_config&.default_fallback
      if default_url.present?
        redirect_to default_url, allow_other_host: true, status: :found  # 302 — not canonical
      else
        render_not_found
      end
    end
  end

  def execute_render_decision(decision)
    case decision[:action]
    when :redirect
      redirect_to decision[:url], allow_other_host: true
    when :render
      decision[:locals]&.each do |key, value|
        instance_variable_set(:"@#{key}", value)
      end
      render template: decision[:template], formats: [:html]
    when :default_redirect
      @name = decision[:name]
      render template: "public/display/default_redirect", formats: [:html]
    end
  end

  def assign_generic_data(link)
    data = LinkDisplayService.generic_data_for_link(link)
    @page_title = data[:page_title]
    @page_subtitle = data[:page_subtitle]
    @page_image = data[:page_image]
    @page_full_path = data[:page_full_path]
    @domain = data[:domain]
    @tracking_campaign = data[:tracking_campaign]
    @tracking_source = data[:tracking_source]
    @tracking_medium = data[:tracking_medium]
    @tracking_data = data[:tracking_data]
  end

  def url_param
    params.permit(:url)[:url]
  end

  def go_to_fallback_param
    ActiveModel::Type::Boolean.new.cast(params.permit(:go_to_fallback)[:go_to_fallback])
  end

  def grovs_redirect
    params.permit(:grovs_redirect)[:grovs_redirect]
  end
end
