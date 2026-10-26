class ProjectSerializer < BaseSerializer
  attributes :id, :name, :identifier, :test


  def build(**)
    h = super()
    # display_host, like Link/QuickLink/Notification: the dashboard must show the host links actually resolve on.
    h["domain"] = record.domain_for_project&.display_host
    h["hash_id"] = record.hashid
    h
  end
end
