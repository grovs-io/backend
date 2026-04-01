class Notification < ApplicationRecord
  include Hashid::Rails

  has_one :notification_target, dependent: :destroy
  belongs_to :project

  has_many :notification_messages, dependent: :destroy

  def access_url
    url = project&.domain_for_project&.full_domain ? "#{project.domain_for_project.full_domain}/mm/#{self.hashid}" : nil
    if url && url.start_with?("http")
      return "https://#{url}"
    end

    url
  end
end
