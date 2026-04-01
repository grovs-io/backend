class WebConfigurationSerializer < BaseSerializer
  attributes


  def build(**)
    h = super()
    h["domains"] = record.web_configuration_linked_domains.map(&:domain)
    h
  end
end
