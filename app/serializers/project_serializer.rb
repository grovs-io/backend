class ProjectSerializer < BaseSerializer
  attributes :id, :name, :identifier, :test


  def build(**)
    h = super()
    h["domain"] = record.domain_for_project&.full_domain
    h["hash_id"] = record.hashid
    h
  end
end
