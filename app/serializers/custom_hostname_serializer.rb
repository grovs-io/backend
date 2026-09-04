class CustomHostnameSerializer < BaseSerializer
  attributes :hostname, :status, :ssl_status, :verification_errors, :source, :purpose,
             :ssl_method, :ssl_validation_txt_records,
             :ownership_verification_txt_name, :ownership_verification_txt_value,
             :last_checked_at

  def build(**)
    h = super()
    h["cname_target"] = record.manual? ? Grovs.ingress_host : CloudflareCustomHostnameService.cname_target
    h["setup_records"] = setup_records if record.manual?
    h
  end

  private

  # Certificate first: a CNAME added before the cert makes the LB serve its default one.
  def setup_records
    [
      { "kind" => "certificate", "type" => nil, "name" => nil, "value" => nil,
        "note" => "Issue a certificate covering #{record.hostname} and attach it to your load " \
                  "balancer's HTTPS listener. The validation record comes from your certificate authority." },
      { "kind" => "dns", "type" => "CNAME", "name" => record.hostname, "value" => Grovs.ingress_host,
        "note" => "Add this only after the certificate is attached." }
    ]
  end
end
