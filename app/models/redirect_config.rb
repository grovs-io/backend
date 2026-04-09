class RedirectConfig < ApplicationRecord
  belongs_to :project

  validates :default_fallback, url: true, allow_blank: true

  has_many :redirects, dependent: :delete_all

  has_one :ios_phone_redirect, -> {where(platform: Grovs::Platforms::IOS, variation: Grovs::Platforms::PHONE)}, class_name: 'Redirect'
  has_one :ios_tablet_redirect, -> {where(platform: Grovs::Platforms::IOS, variation: Grovs::Platforms::TABLET)}, class_name: 'Redirect'
  has_one :android_phone_redirect, -> {where(platform: Grovs::Platforms::ANDROID, variation: Grovs::Platforms::PHONE)}, class_name: 'Redirect'
  has_one :android_tablet_redirect, -> {where(platform: Grovs::Platforms::ANDROID, variation: Grovs::Platforms::TABLET)}, class_name: 'Redirect'

  has_one :desktop_all_redirect, -> {where(platform: Grovs::Platforms::DESKTOP, variation: Grovs::Platforms::DESKTOP)}, class_name: 'Redirect'

  before_destroy :cleanup_link_dependencies

  has_many :links, dependent: :delete_all

  def cleanup_link_dependencies
    link_ids = links.select(:id)
    CustomRedirect.where(link_id: link_ids).delete_all
    PurchaseEvent.where(link_id: link_ids).update_all(link_id: nil)
    VisitorLastVisit.where(link_id: link_ids).update_all(link_id: nil)
  end

  def redirect_for_platform_and_variation(platform, variation)
    redirect = Redirect.find_by(redirect_config_id: id, platform: platform, variation: variation)
    unless redirect
      application = project.instance.application_for_platform(platform)
      redirect = Redirect.create(redirect_config_id: id, platform: platform, variation: variation, application_id: application.id)
    end

    redirect
  end
end
