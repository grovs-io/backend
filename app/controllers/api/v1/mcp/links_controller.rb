class Api::V1::Mcp::LinksController < Api::V1::Mcp::BaseController
  # wrap_parameters nests JSON bodies under :link, breaking the strict request contract.
  wrap_parameters false
  include Api::V1::Concerns::AnalyticsRetentionGate

  before_action :load_mcp_project
  before_action :validate_campaign_id!, only: [:create, :index]
  before_action :enforce_ch_retention_window!, only: [:index]

  # POST /api/v1/mcp/links
  def create
    # MCP-specific: name is required so links are identifiable in the dashboard.
    # Link model has no name validation — other create paths (SDK, dashboard) allow blank names.
    params.require(:name)

    link = ActiveRecord::Base.transaction do
      created = LinkManagementService.new(project: @project).create(
        link_attrs: link_params,
        tags: params[:tags],
        data: params[:data],
        image: params[:image],
        image_url: params[:image_url],
        campaign_id: campaign_id_param,
        custom_redirects: mcp_custom_redirect_params
      )
      # hidden=true maps to sdk_generated=true, hiding the link from the dashboard.
      LinkManagementService.new(project: @project).set_hidden(link: created, hidden: true) if params[:hidden] == true
      audit!("link.created", instance_id: @project.instance_id, target: audit_target(created).merge("path" => created.path),
             changes: { "after" => link_params.to_h })
      created
    end

    render json: { link: LinkSerializer.serialize(link.reload) }, status: :created
  rescue ArgumentError, JSON::ParserError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/mcp/links/by-path/:path
  def show
    domain = @project.domain
    unless domain
      render json: { error: "Project has no domain configured" }, status: :not_found
      return
    end

    link = domain.links.find_by(path: params[:path], active: true)
    unless link
      render json: { error: "Link not found" }, status: :not_found
      return
    end

    render json: { link: LinkSerializer.serialize(link) }, status: :ok
  end

  # PATCH /api/v1/mcp/links/:id
  def update
    # Link does NOT include Hashid::Rails — LinkSerializer returns raw integer ids
    link = Link.find_by(id: params[:id])
    unless link && link.domain.project_id == @project.id
      render json: { error: "Link not found" }, status: :not_found
      return
    end

    validate_campaign_id!
    return if performed?

    tracked = link_params.to_h.keys
    before = link.attributes.slice(*tracked)
    updated = ActiveRecord::Base.transaction do
      u = LinkManagementService.new(project: @project).update(
        link: link,
        link_attrs: link_params,
        tags: params[:tags],
        data: params[:data],
        image: params[:image],
        campaign_id: campaign_id_param,
        custom_redirects: mcp_custom_redirect_params
      )
      # hidden can be true (hide) or false (show) on update — only skip if not provided.
      LinkManagementService.new(project: @project).set_hidden(link: u, hidden: params[:hidden]) unless params[:hidden].nil?
      audit!("link.updated", instance_id: @project.instance_id, target: audit_target(u).merge("path" => u.path),
             changes: { "before" => before, "after" => u.attributes.slice(*tracked) })
      u
    end

    render json: { link: LinkSerializer.serialize(updated.reload) }, status: :ok
  rescue ArgumentError, JSON::ParserError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/mcp/links/:id
  def archive
    link = Link.find_by(id: params[:id])
    unless link && link.domain.project_id == @project.id
      render json: { error: "Link not found" }, status: :not_found
      return
    end

    archived = ActiveRecord::Base.transaction do
      a = LinkManagementService.new(project: @project).archive(link: link)
      audit!("link.deleted", instance_id: @project.instance_id, target: audit_target(a).merge("path" => a.path))
      a
    end
    render json: { link: LinkSerializer.serialize(archived) }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/mcp/links/search
  def index
    result = LinkStatisticsQuery.new(
      params: params,
      project: @project,
      campaign_id: campaign_id_param
    ).call

    render json: result, status: :ok
  end

  private

  def link_params
    params.permit(:name, :title, :subtitle, :path, :image_url, :show_preview_ios,
                  :show_preview_android, :copy_to_clipboard_ios, :copy_to_clipboard_android,
                  :ads_platform, :tracking_campaign,
                  :tracking_medium, :tracking_source)
  end

  # Accepts two shapes for each platform:
  #   1. Flat string  — { ios: "https://..." }              (MCP tool schema format)
  #   2. Nested hash — { ios: { url: "...", open_app_if_installed: true } }
  #
  # Flat strings default open_app_if_installed=true so iOS/Android still
  # open the installed app when present (matches the most useful deep-link default).
  def mcp_custom_redirect_params
    return {} unless params[:custom_redirects].present?

    %i[ios android desktop].each_with_object({}) do |platform, result|
      value = params.dig(:custom_redirects, platform)
      next if value.blank?

      result[platform] = if value.is_a?(String)
                           { "url" => value, "open_app_if_installed" => true }
                         else
                           value.permit(:url, :open_app_if_installed).to_h
                         end
    end
  end
end
