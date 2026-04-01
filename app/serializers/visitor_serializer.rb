class VisitorSerializer < BaseSerializer
  attributes :id, :uuid, :sdk_identifier, :sdk_attributes,
             :inviter_id, :web_visitor, :created_at, :updated_at

  def self.simple(visitor)
    return nil if visitor.nil?
    json = new(visitor).build(skip_invites: true)
    json["uuid"] = visitor.uuid
    json.delete("inviter_id")
    json
  end


  def build(slim: false, skip_invites: false, **)
    h = super()
    unless slim
      h["inviter"] = record.inviter&.sdk_identifier
      unless skip_invites
        h["invited"] = record.invited_visitors.map { |v| self.class.simple(v) }
      end
    end
    h
  end
end
