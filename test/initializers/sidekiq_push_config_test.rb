require "test_helper"

class SidekiqPushConfigTest < ActiveSupport::TestCase
  def queues(file)
    config = YAML.safe_load(ERB.new(Rails.root.join("config/#{file}").read).result, permitted_classes: [Symbol])
    config.fetch(:queues).map { |q| Array(q).first }
  end

  test "the push worker serves only the push queue, which is what lifts the handoff cap" do
    assert_equal %w[push], queues("sidekiq_push.yml")
  end

  test "the egress-only config leaves push to the push worker" do
    assert_equal %w[egress journeys egress_exports], queues("sidekiq_egress_only.yml")
  end

  test "both egress configs serve journeys, so they run beside push without being part of the push-only worker" do
    assert_includes queues("sidekiq_egress.yml"), "journeys"
    assert_includes queues("sidekiq_egress_only.yml"), "journeys"
  end

  test "the default egress config still serves push, so installs without a push worker keep delivering" do
    assert_includes queues("sidekiq_egress.yml"), "push"
  end
end
