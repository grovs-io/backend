class IosPushConfigurationSerializer < BaseSerializer
  attributes


  def build(**)
    h = super()
    h["certificate"] = record.certificate.attached? ? record.certificate.filename.to_s : nil
    h["key_id"] = record.certificate_password
    h
  end
end
