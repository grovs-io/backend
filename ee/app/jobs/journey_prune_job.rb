class JourneyPruneJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  BATCH = 10_000
  MAX_BATCHES = 20
  LEAVER_KEPT = 1.day

  # Rows of finished journeys, and leavers re-entry no longer needs; each kind bounded per night on its own.
  def perform
    @budget = MAX_BATCHES
    # A segment journey's sweep needs its leavers' rows; an event journey's only stop a retried or late event.
    Journey.where("re_entry ->> 'mode' = 'after_exit' AND entry ->> 'type' = 'event'").where.not(status: "draft").find_each do |journey|
      prune(JourneyPerson.where(journey_id: journey.id, state: "left").where.not(left_reason: "held").where(left_at: ...LEAVER_KEPT.ago))
    end
    @budget = MAX_BATCHES
    Journey.where("re_entry ->> 'mode' = 'after_days'").where.not(status: "draft").find_each do |journey|
      cutoff = journey.re_entry["days"].to_i.days.ago
      prune(JourneyPerson.where(journey_id: journey.id, state: "left").where(left_at: ...cutoff))
    end
    @budget = MAX_BATCHES
    Journey.where(status: "ended").where.not(finished_at: nil).pluck(:id).each { |id| prune(JourneyPerson.where(journey_id: id)) }
  end

  private

  def prune(scope)
    while @budget.positive?
      deleted = JourneyPerson.where(id: scope.limit(BATCH).select(:id)).delete_all
      break if deleted.zero?

      @budget -= 1
      break if deleted < BATCH
    end
  end
end
