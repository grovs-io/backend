class Api::V1::SmartBannersController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false

  PRELOAD = [{ default_link: :domain }, { icon_attachment: :blob }].freeze
  ARRAY_FIELDS = %w[platforms url_include url_exclude].freeze

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  rescue_from ActiveRecord::RecordInvalid, with: :render_validation_error

  def index
    render json: { smart_banners: serialize(@project.smart_banners.ordered.includes(*PRELOAD).to_a) }, status: :ok
  end

  def status
    domains = web_configuration_linked_domains
    sdk_last_seen_at = Project.where(id: @project.id).pick(:web_sdk_last_seen_at)
    render json: { web_configured: domains.any?, domains: domains, sdk_last_seen_at: sdk_last_seen_at&.iso8601 }, status: :ok
  end

  def show
    render json: { smart_banner: serialize([banner]).first }, status: :ok
  end

  def create
    created = ActiveRecord::Base.transaction do
      record = SmartBannerManagementService.create(project: @project, attrs: banner_params, icon: icon_param)
      audit!("smart_banner.created", instance_id: @project.instance_id, target: banner_target(record),
                                     changes: { "before" => {}, "after" => audited_fields(record) })
      record
    end
    render json: { smart_banner: SmartBannerSerializer.new(created).build }, status: :created
  end

  def update
    updated = ActiveRecord::Base.transaction do
      record = SmartBannerManagementService.update(banner: banner, attrs: banner_params, icon: icon_param,
                                                   remove_icon: remove_icon_param)
      audit!("smart_banner.updated", instance_id: @project.instance_id, target: banner_target(record),
                                     changes: audit_diff(record))
      record
    end
    render json: { smart_banner: serialize([updated]).first }, status: :ok
  end

  def destroy
    ActiveRecord::Base.transaction do
      # Blocks until in-flight link creations commit, so delete_all sees their rows.
      banner.lock!
      banner.destroy!
      audit!("smart_banner.deleted", instance_id: @project.instance_id, target: banner_target(banner))
    end
    render json: {}, status: :ok
  end

  def duplicate
    created = ActiveRecord::Base.transaction do
      record = SmartBannerManagementService.duplicate(banner: banner)
      audit!("smart_banner.created", instance_id: @project.instance_id, target: banner_target(record),
                                     changes: { "before" => {}, "after" => audited_fields(record) })
      record
    end
    render json: { smart_banner: SmartBannerSerializer.new(created).build }, status: :created
  end

  def reorder
    banners = ActiveRecord::Base.transaction do
      ordered = SmartBannerManagementService.reorder(project: @project, ids: Array(params[:ids]))
      audit!("smart_banner.reordered", instance_id: @project.instance_id,
                                       target: { "type" => "project", "id" => @project.id },
                                       changes: { "after" => { "ids" => ordered.map(&:id) } })
      ordered
    end
    render json: { smart_banners: serialize(banners) }, status: :ok
  rescue SmartBannerManagementService::InvalidOrder => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def banner
    @banner ||= @project.smart_banners.find(params.require(:banner_id))
  end

  def web_configuration_linked_domains
    application = @project.instance.application_for_platform(Grovs::Platforms::WEB)
    config = application&.configuration
    config&.web_configuration_linked_domains&.map(&:domain) || []
  end

  def banner_target(record)
    audit_target(record).merge("name" => record.name)
  end

  def audited_fields(record)
    record.attributes.except("created_at", "updated_at")
  end

  def serialize(banners)
    stats = SmartBannerStatsService.for_banners(@project, banners)
    banners.map { |b| SmartBannerSerializer.new(b).build(stats: stats.fetch(b.id, SmartBannerSerializer::EMPTY_STATS)) }
  end

  def banner_params
    permitted = params.require(:smart_banner).permit(
      :name, :status, :position, :title, :subtitle, :button_text, :background_color, :text_color,
      :button_color, :button_text_color, :dismiss_days, :open_hide_days, platforms: [], url_include: [], url_exclude: []
    )
    ARRAY_FIELDS.each { |field| permitted[field] = permitted[field].compact_blank if permitted.key?(field) }
    permitted
  end

  def icon_param
    icon = params.dig(:smart_banner, :icon)
    icon.respond_to?(:read) ? icon : nil
  end

  def remove_icon_param
    ActiveModel::Type::Boolean.new.cast(params.dig(:smart_banner, :remove_icon)) == true
  end

  def render_validation_error(exception)
    render json: { error: exception.message }, status: :unprocessable_entity
  end
end
