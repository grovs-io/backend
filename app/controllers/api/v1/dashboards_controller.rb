class Api::V1::DashboardsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :load_dashboard, except: %i[index create]
  before_action :load_widget, only: %i[update_widget destroy_widget]

  def index
    dashboards = @project.dashboards.ordered.includes(:widgets)
    render json: { dashboards: DashboardSerializer.serialize(dashboards.to_a) }, status: :ok
  end

  def create
    dashboard = @project.dashboards.build(name: params[:name], created_by: current_user,
                                          position: @project.dashboards.count)
    save_and_render(dashboard) do
      audit_dashboard!("dashboard.created", dashboard, changes: { "after" => { "name" => dashboard.name } })
      { dashboard: DashboardSerializer.serialize(dashboard) }
    end
  end

  def update
    @dashboard.name = params[:name] if params.key?(:name)
    unless @dashboard.valid?
      return render json: { error: @dashboard.errors.full_messages.first }, status: :unprocessable_entity
    end

    DashboardWidget.transaction do
      if params.key?(:widget_order)
        reorder_widgets(Array(params[:widget_order]))
        @dashboard.updated_at = Time.current
      end
      @dashboard.save!
    end
    audit_dashboard!("dashboard.updated", @dashboard, changes: audit_diff(@dashboard))
    render json: { dashboard: DashboardSerializer.serialize(@dashboard.reload) }, status: :ok
  end

  def destroy
    @dashboard.destroy!
    audit_dashboard!("dashboard.deleted", @dashboard, changes: { "before" => { "name" => @dashboard.name } })
    render json: { message: 'Dashboard deleted' }, status: :ok
  end

  def create_widget
    widget = @dashboard.widgets.build(widget_params.merge(position: @dashboard.widgets.count))
    save_and_render(widget) do
      audit_widget!("added", widget)
      { widget: DashboardWidgetSerializer.serialize(widget) }
    end
  end

  def update_widget
    @widget.assign_attributes(widget_params)
    save_and_render(@widget) do
      audit_widget!("updated", @widget)
      { widget: DashboardWidgetSerializer.serialize(@widget) }
    end
  end

  def destroy_widget
    @widget.destroy!
    audit_widget!("removed", @widget)
    render json: { message: 'Widget deleted' }, status: :ok
  end

  private

  def audit_dashboard!(action, dashboard, target: {}, changes: {})
    audit!(action, instance_id: @project.instance_id, target: audit_target(dashboard).merge(target), changes: changes)
  end

  def audit_widget!(change, widget)
    audit_dashboard!("dashboard.updated", @dashboard, target: { "widget_id" => widget.id },
                                                      changes: { "widget" => change, "title" => widget.title })
  end

  def load_dashboard
    @dashboard = @project.dashboards.find_by(id: params[:dashboard_id])
    render json: { error: 'Dashboard not found' }, status: :not_found unless @dashboard
  end

  def load_widget
    @widget = @dashboard.widgets.find_by(id: params[:widget_id])
    render json: { error: 'Widget not found' }, status: :not_found unless @widget
  end

  def reorder_widgets(ids)
    own = @dashboard.widgets.index_by(&:id)
    ordered = ids.select { |i| i.is_a?(String) || i.is_a?(Integer) }.map { |i| own[i.to_i] }.compact.uniq
    ordered += (own.values - ordered)
    ordered.each_with_index { |w, i| w.update_column(:position, i) }
  end

  def save_and_render(record)
    if record.save
      render json: yield, status: :ok
    else
      render json: { error: record.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def widget_params(source = params)
    permitted = source.permit(:title, :subtitle, :kind, :panel, :viz, :size, query: {}, filters: [[:field, :operator, :value, { value: [] }]])
    permitted[:filters] = permitted[:filters].map(&:to_h) if permitted.key?(:filters)
    permitted[:query] = permitted[:query].to_h if permitted.key?(:query)
    permitted.to_h
  end
end
