require "test_helper"
require "rake"

class SeedEventsTaskTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :redirect_configs, :devices

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @instance = instances(:one)
    @project = @instance.production
    @canary = Event.create!(project_id: @project.id, device: devices(:ios_device),
                            event: Grovs::Events::VIEW, platform: "ios")
    Rake::Task["seed_events:generate"].reenable
    @saved = ENV.values_at("INSTANCE_ID", "CONFIRM", "EVENTS", "DEVICES", "DAYS")
    ENV["EVENTS"] = "1"; ENV["DEVICES"] = "1"; ENV["DAYS"] = "1"
  end

  teardown do
    ENV["INSTANCE_ID"], ENV["CONFIRM"], ENV["EVENTS"], ENV["DEVICES"], ENV["DAYS"] = @saved
  end

  test "aborts and deletes nothing without a matching CONFIRM" do
    ENV["INSTANCE_ID"] = @instance.id.to_s
    ENV.delete("CONFIRM")

    assert_raises(SystemExit) { capture_io { Rake::Task["seed_events:generate"].invoke } }
    assert Event.exists?(@canary.id), "the destructive wipe must not run without CONFIRM"
  end

  test "aborts when CONFIRM does not match the instance id" do
    ENV["INSTANCE_ID"] = @instance.id.to_s
    ENV["CONFIRM"] = "#{@instance.id}0"

    assert_raises(SystemExit) { capture_io { Rake::Task["seed_events:generate"].invoke } }
    assert Event.exists?(@canary.id), "a mismatched CONFIRM must not run the wipe"
  end
end
