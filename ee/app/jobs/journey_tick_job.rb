class JourneyTickJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  PARALLELISM = 6
  STALE_CLAIM = 10.minutes

  # Enqueue only: step jobs per journey with due people, stale claims back to due, ended journeys closed once empty.
  def perform
    return unless Journeys.running?

    opening = Journey.where(status: "live", entry_opened_at: nil)
    opening.where(start_at: nil).or(opening.where(start_at: ..Time.current)).find_each(&:open_entry!)
    Journey.where(status: %w[live paused ended], finished_at: nil).find_each do |journey|
      people = JourneyPerson.where(journey_id: journey.id)
      people.where(state: "claimed", claimed_at: ...STALE_CLAIM.ago).update_all(state: "active", claimed_at: nil)
      next journey.finish! if journey.status == "ended" && !people.inside.exists?
      next if journey.status == "paused"

      due = people.where(state: "active", due_at: ..Time.current).limit(PARALLELISM * Journeys::Stepper::BATCH).count
      (due.to_f / Journeys::Stepper::BATCH).ceil.times { |slot| JourneyStepJob.perform_async(journey.id, slot) }
    rescue StandardError => e
      Rails.logger.error("journeys.tick_failed journey=#{journey.id} #{e.class}: #{e.message}")
    end
  end
end
