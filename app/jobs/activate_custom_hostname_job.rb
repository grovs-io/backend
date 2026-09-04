class ActivateCustomHostnameJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  def perform(custom_hostname_id)
    custom_hostname = CustomHostname.find_by(id: custom_hostname_id)
    return unless custom_hostname&.manual? && custom_hostname.status == "pending"

    # A spoofed Host header can enqueue this; only the probe proves DNS actually cut over.
    result = SelfHostedDomainVerificationService.verify(custom_hostname.hostname, source: "first_hit")
    if result.active
      CustomHostnameActivation.apply!(custom_hostname)
    else
      CustomHostnameActivation.record_failure!(custom_hostname, result.error)
    end
  end
end
