# The inbox is gone. A job queued before the deploy still names this class, and ends here instead of failing.
class SendMessagesJob
  include Sidekiq::Job

  def perform(*); end
end
