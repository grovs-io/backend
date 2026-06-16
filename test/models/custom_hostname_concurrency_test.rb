require "test_helper"

# Two genuinely concurrent inserts for the same project, on two real DB connections,
# proving the unique index on project_id — not the app-level Conflict precheck — is
# what stops a double-provision under a race.
#
# Cross-connection visibility requires committed data, so transactional fixtures are
# off and rows are cleaned up explicitly. The outcome is deterministic regardless of
# thread timing: the index permits exactly one row per project, so one insert wins and
# the other raises RecordNotUnique.
class CustomHostnameConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  fixtures :instances, :projects, :domains

  setup    { CustomHostname.delete_all }
  teardown { CustomHostname.delete_all }

  test "two concurrent inserts for one project: the DB index lets exactly one win" do
    project_id = projects(:one).id
    domain_id  = domains(:one).id

    go = Queue.new        # release both threads at once to force overlap
    results = Queue.new

    threads = Array.new(2) do |i|
      Thread.new do
        go.pop
        ActiveRecord::Base.connection_pool.with_connection do
          CustomHostname.create!(project_id: project_id, domain_id: domain_id,
                                 hostname: "links.race#{i}.com", status: "active", source: "saas")
          results << :ok
        rescue ActiveRecord::RecordNotUnique
          results << :conflict
        end
      end
    end

    2.times { go << :start }
    threads.each(&:join)

    outcomes = Array.new(results.size) { results.pop }
    assert_equal 1, outcomes.count(:ok), "exactly one concurrent insert must succeed"
    assert_equal 1, outcomes.count(:conflict), "the loser must hit the DB unique index, not slip through"
    assert_equal 1, CustomHostname.where(project_id: project_id).count
  end
end
