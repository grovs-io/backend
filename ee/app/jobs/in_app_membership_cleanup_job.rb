class InAppMembershipCleanupJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  # The nightly run (no keys) also drops the views of campaigns that ended a month ago.
  def perform(keys = nil)
    InAppMemberships.cleanup(keys)
    InAppViews.purge_ended if keys.nil?
  end
end
