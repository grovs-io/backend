class Api::V1::Mcp::LinksController < Api::V1::Mcp::BaseController
  before_action :load_mcp_project

  # POST /api/v1/mcp/links
  def create
    # MCP-specific: name is required so links are identifiable in the dashboard.
    # Link model has no name validation — other create paths (SDK, dashboard) allow blank names.
    params.require(:name)

    link = LinkManagementService.new(project: @project).create(
      link_attrs: link_params,
      tags: params[:tags],
      data: params[:data],
      image: params[:image],
      image_url: params[:image_url],
      campaign_id: params[:campaign_id],
      custom_redirects: mcp_custom_redirect_params
    )
    # hidden=true maps to sdk_generated=true, hiding the link from the dashboard.
    # Default is visible (sdk_generated=false, set by LinkManagementService).
    # update_column bypasses callbacks intentionally — no cache or callbacks needed for this flag.
    link.update_column(:sdk_generated, true) if params[:hidden] == true

    render json: { link: LinkSerializer.serialize(link.reload) }, status: :created
  rescue ArgumentError => e
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

    updated = LinkManagementService.new(project: @project).update(
      link: link,
      link_attrs: link_params,
      tags: params[:tags],
      data: params[:data],
      image: params[:image],
      campaign_id: params[:campaign_id],
      custom_redirects: mcp_custom_redirect_params
    )
    # On update, hidden can be true (hide) or false (show) — only skip if not provided.
    # update_column bypasses callbacks intentionally — see CLAUDE.md gotcha #5.
    updated.update_column(:sdk_generated, params[:hidden]) unless params[:hidden].nil?

    render json: { link: LinkSerializer.serialize(updated.reload) }, status: :ok
  rescue ArgumentError => e
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

    archived = LinkManagementService.new(project: @project).archive(link: link)
    render json: { link: LinkSerializer.serialize(archived) }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/mcp/links/search
  def index
    result = LinkStatisticsQuery.new(
      params: params,
      project: @project,
      campaign_id: params[:campaign_id]
    ).call

    render json: result, status: :ok
  end

  private

  def link_params
    params.permit(:name, :title, :subtitle, :path, :image_url, :show_preview_ios,
                  :show_preview_android, :ads_platform, :tracking_campaign,
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
