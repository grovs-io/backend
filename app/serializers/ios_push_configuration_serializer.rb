class IosPushConfigurationSerializer < BaseSerializer
  attributes


  def build(**)
    h = super()
    h["certificate"] = record.certificate.attached? ? record.certificate.filename.to_s : nil
    # Never emit the stored APNs password — a member-readable config must not leak the secret.
    h["configured"] = record.certificate_password.present?
    h
  end
end
