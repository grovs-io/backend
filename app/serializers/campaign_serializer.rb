class CampaignSerializer < BaseSerializer
  attributes :id, :name, :archived, :created_at


  def build(**)
    h = super()
    h["has_links"] = record.archived? ? record.links.exists? : record.links.active.exists?
    h
  end
end
