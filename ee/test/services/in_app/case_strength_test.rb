require "test_helper"
require_relative "../../support/in_app_shared_cases"
require_relative "../../support/in_app_reference_engine"

# Each engine here gets one rule wrong; the shared cases must catch it, or an SDK could make the same mistake unnoticed.
class InAppCaseStrengthTest < ActiveSupport::TestCase
  class ForgetsViewsAtSync < InAppReferenceEngine
    def sync(response)
      super
      @views = []
    end
  end

  class AsksAgainAfterAnAnswer < InAppReferenceEngine
    def answer(_campaign_id) = nil
  end

  class CountsDaysInUtc < InAppReferenceEngine
    private

    def day_of(time) = time.utc.strftime("%Y-%m-%d")
  end

  class ShowsBraces < InAppReferenceEngine
    private

    def fill(template, event, encode: false)
      super(template.gsub(FIELD, "\u0000\0").gsub(/(?<!\u0000)\{\{/, "").delete("\u0000"), event, encode: encode)
    end
  end

  class UsesWholeHourOffsets < InAppReferenceEngine
    private

    def local(time) = (time + ((@device.fetch("utc_offset_minutes", 0) / 60) * 3600)).utc
  end

  class ChecksTodayForOvernightHours < InAppReferenceEngine
    private

    def opened_on(_schedule, here, _clock) = here
  end

  def failing_cases(engine_class)
    InAppSharedCases.expanded.select { |kase| wrong?(engine_class.new(kase), kase["steps"]) }.pluck("name")
  end

  def wrong?(engine, steps)
    steps.any? do |step|
      next engine.start_session && false if step["session_start"]
      next engine.sync(step["sync"]) && false if step["sync"]
      next engine.answer(step["answer"]) && false if step["answer"]

      result = engine.track(step["event"], step["at"])
      step["expect"].any? { |key, wanted| result[key] != wanted }
    end
  end

  test "the reference engine passes every case" do
    assert_empty failing_cases(InAppReferenceEngine)
  end

  WRONG = [ForgetsViewsAtSync, CountsDaysInUtc, ChecksTodayForOvernightHours, ShowsBraces, UsesWholeHourOffsets].freeze

  WRONG.each do |engine_class|
    test "an engine that #{engine_class.name.demodulize.underscore.humanize.downcase} fails at least one case" do
      assert_not_empty failing_cases(engine_class)
    end
  end
end
