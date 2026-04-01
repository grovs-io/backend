class AndroidConfiguration < ApplicationRecord
  belongs_to :application
  has_one :android_push_configuration, dependent: :destroy
  has_one :android_server_api_key, dependent: :destroy

  validates :application_id, uniqueness: true

  after_destroy :clear_configuration_cache, :delete_application

  after_update :clear_configuration_cache
  after_touch :clear_configuration_cache

  private
  # Each application has a single configuration, so we can safely delete it with all the rules
  def delete_application
    application.destroy
  end

    
  def clear_configuration_cache
    application.clear_configuration_cache
  end
end
