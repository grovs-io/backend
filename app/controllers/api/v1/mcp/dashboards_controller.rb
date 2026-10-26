class Api::V1::Mcp::DashboardsController < Api::V1::DashboardsController
  include McpProjectController

  MAX_WIDGETS = DashboardWidget::MAX_PER_DASHBOARD

  # One call builds the dashboard and its metric widgets; any invalid widget rolls back the lot.
  def create
    widgets = params[:widgets].nil? ? [] : params[:widgets]
    unless widgets.is_a?(Array) && widgets.all?(ActionController::Parameters) && widgets.size <= MAX_WIDGETS
      return render json: { error: "widgets must be a list of at most #{MAX_WIDGETS} objects" }, status: :unprocessable_entity
    end

    dashboard = @project.dashboards.build(name: params[:name], created_by: current_user, position: @project.dashboards.count)
    error = build_with_widgets(dashboard, widgets)
    return render json: { error: error }, status: :unprocessable_entity if error

    audit_dashboard!("dashboard.created", dashboard, changes: { "after" => { "name" => dashboard.name, "widgets" => widgets.size } })
    render json: { dashboard: DashboardSerializer.serialize(dashboard.reload) }, status: :ok
  end

  private

  def build_with_widgets(dashboard, widgets)
    error = nil
    Dashboard.transaction do
      unless dashboard.save
        error = dashboard.errors.full_messages.first
        raise ActiveRecord::Rollback
      end
      widgets.each_with_index do |w, i|
        group_by = w.dig(:query, :group_by).to_s
        if McpIdentityPolicy.blocked?(group_by, builtin: ::Analytics::MetricQuery::DIMENSIONS)
          error = "widget #{i + 1}: #{group_by} is not available through MCP"
          raise ActiveRecord::Rollback
        end
        widget = dashboard.widgets.build(widget_params(w).except("kind", "panel").merge("kind" => "metric", "position" => i))
        next if widget.save

        error = "widget #{i + 1}: #{widget.errors.full_messages.first}"
        raise ActiveRecord::Rollback
      end
    end
    error
  end
end
