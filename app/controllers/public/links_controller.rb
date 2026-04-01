class Public::LinksController < Public::BaseController
  def open_app_link
    link = LinksService.link_for_request(request)
    unless link
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

    if @project
      name_and_image = WebConfigurationService.name_and_image_for_project_and_platform(@project, @device.platform)
      @name, @image = name_and_image.values_at(:name, :image)
    end

    @redirect_url = LinksService.build_redirect_url_for_preview(url_param, link, @device)
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
