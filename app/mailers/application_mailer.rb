class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'noreply@grovs.io')
  layout 'mailer'

  private

  def dashboard_url(path, project)
    env_type = project.test? ? "Test" : "Production"
    "#{ENV.fetch('REACT_HOST_PROTOCOL', 'https://')}#{ENV.fetch('REACT_HOST')}#{path}" \
      "?instance_id=#{project.instance_id}&env_type=#{env_type}"
  end
end
