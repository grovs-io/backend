class AndroidPushConfigurationSerializer < BaseSerializer
  attributes :firebase_project_id


  def build(**)
    h = super()
    h["certificate"] = record.certificate.attached? ? record.certificate.filename.to_s : nil
    h
  end
end
