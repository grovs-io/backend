require "test_helper"
require "rake"

class AuditVerifyTaskTest < ActiveSupport::TestCase
  include AuditTestHelper
  fixtures :instances

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @instance = instances(:one)
    entitle!(@instance)
    2.times { AuditEvent.record(instance_id: @instance.id, action: "link.created", actor: AuditActor.system("t")) }
    Rake::Task["audit:verify"].reenable
  end

  test "prints OK for a sound chain" do
    out, = capture_io { Rake::Task["audit:verify"].invoke(@instance.id.to_s) }
    assert_match(/OK 2 events/, out)
  end

  test "aborts on a broken chain" do
    AuditEvent.connection.execute("DELETE FROM audit_events WHERE instance_id = #{@instance.id} AND sequence = 1")
    err = assert_raises(SystemExit) { capture_io { Rake::Task["audit:verify"].invoke(@instance.id.to_s) } }
    assert_equal 1, err.status
  end
end
