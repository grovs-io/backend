class JourneySweepJob
  include Sidekiq::Job
  sidekiq_options queue: :journeys, retry: 3

  PAGE = 1_000

  # Lets in, a page per job, entry-segment members who were never in the journey; the tick re-enqueues until it starts.
  def perform(journey_id, after = 0)
    return unless Journeys.running?

    journey = Journey.find_by(id: journey_id)
    return unless journey&.entry_open?

    journey.update_columns(entry_opened_at: Time.current) if after.zero?
    key = journey.segment_keys.dig("entry", "key")
    return if key.nil?

    ids = SegmentMembership.where(project_id: journey.project_id, segment_key: key, visitor_id: (after + 1)..).order(:visitor_id).limit(PAGE)
                           .pluck(:visitor_id)
    return if ids.empty?

    people = Journeys.people_of(ids)
    known = JourneyPerson.where(journey_id: journey.id, person_key: people.map(&:last)).pluck(:person_key).to_set
    Journeys::Entry.call(journey, people.reject { |_, person| known.include?(person) }, run: false)
    JourneyStepJob.perform_async(journey.id)
    self.class.perform_async(journey_id, ids.last) if ids.size == PAGE
  end
end
