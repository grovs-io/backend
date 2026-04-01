class ActionSerializer < BaseSerializer
  attributes :id, :handled, :created_at, :updated_at


  def build(**)
    h = super()
    h["device"] = DeviceSerializer.serialize(record.device)
    h["link"] = LinkSerializer.serialize(record.link)
    h
  end
end
