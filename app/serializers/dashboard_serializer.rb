class DashboardSerializer < BaseSerializer
  attributes :id, :name, :position, :created_at, :updated_at

  def build(**options)
    h = super
    h['widgets'] = DashboardWidgetSerializer.serialize(record.widgets.to_a)
    h
  end
end
