class DashboardWidgetSerializer < BaseSerializer
  attributes :id, :dashboard_id, :title, :subtitle, :kind, :panel, :viz, :size, :query, :filters, :position, :created_at,
             :updated_at
end
