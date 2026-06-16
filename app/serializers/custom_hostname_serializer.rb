class CustomHostnameSerializer < BaseSerializer
  attributes :hostname, :status, :ssl_status, :verification_errors, :source, :purpose,
             :ssl_method, :ssl_validation_txt_records,
             :ownership_verification_txt_name, :ownership_verification_txt_value,
             :last_checked_at

  def build(**)
    h = super()
    h["cname_target"] = CloudflareCustomHostnameService.cname_target
    h
  end
end
