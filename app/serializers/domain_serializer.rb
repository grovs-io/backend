class DomainSerializer < BaseSerializer
  attributes :domain, :subdomain, :generic_title, :generic_subtitle,
             :google_tracking_id


  def build(**)
    h = super()
    h["generic_image_url"] = record.image_url
    h
  end
end
