class EgressProjectsReconcileJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    wanted = (EventDestination.distinct.pluck(:project_id) | EventStreamToken.active.distinct.pluck(:project_id)).to_set
    have = EventStream::Outbox.enabled_project_ids.to_set
    (wanted ^ have).each do |id|
      project = Project.find_by(id: id)
      next EventStream::Outbox.sync_project!(project) if project

      EventStream::Outbox.disable_project!(id)
      EventStream::Outbox.purge_project!(id)
    end
  end
end
