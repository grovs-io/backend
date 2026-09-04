class RefreshAndroidDeviceModelsJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 2

  def perform
    AndroidDeviceModels.refresh!
  end
end
