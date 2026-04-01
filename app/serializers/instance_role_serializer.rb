class InstanceRoleSerializer < BaseSerializer
  attributes :instance_id, :role


  def build(**)
    h = super()
    h["user"] = UserSerializer.serialize(record.user)
    h
  end
end
