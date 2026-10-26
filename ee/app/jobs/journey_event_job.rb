class JourneyEventJob
  include Sidekiq::Job
  sidekiq_options queue: :journeys, retry: 3

  # rows: [[visitor_id, person_key, event_name, screen_name, properties, created_at_ms, received_ms?], ...] for one project.
  def perform(project_id, rows)
    return unless Journeys.running?

    project = Project.find_by(id: project_id)
    return unless project&.instance&.journeys_enabled?

    Journeys::Signals.new(project, rows).call
  end
end
