class RefreshStoreMetadataJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 1

  def perform(platform, identifier)
    case platform
    when Grovs::Platforms::IOS
      AppstoreService.refresh!(identifier)
    when Grovs::Platforms::ANDROID
      GooglePlayService.refresh!(identifier)
    end
  end
end
