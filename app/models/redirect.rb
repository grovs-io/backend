class Redirect < ApplicationRecord
  belongs_to :redirect_config
  belongs_to :application

  validates :platform, inclusion: { in: Grovs::Platforms::ALL }
  validates :variation, inclusion: { in: Grovs::Platforms::VARIATIONS }

  validate :fallback_must_be_consistent

  def fallback_must_be_consistent
    if appstore == false && fallback_url.nil?
      errors.add(:fallback, "fallback missing")
    end

    if appstore == true && fallback_url != nil
      errors.add(:fallback, "fallback won't be executed")
    end
  end
end
