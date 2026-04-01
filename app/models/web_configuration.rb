class WebConfiguration < ApplicationRecord
  has_many :web_configuration_linked_domains, dependent: :destroy
  belongs_to :application

  validates :application_id, uniqueness: true

  after_destroy :clear_configuration_cache, :delete_application

  after_update :clear_configuration_cache
  after_touch :clear_configuration_cache

  delegate :clear_configuration_cache, to: :application

  private
  # Each application has a single configuration, so we can safely delete it with all the rules
  def delete_application
    application.destroy
  end 
end
