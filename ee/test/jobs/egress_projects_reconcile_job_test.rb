require "test_helper"

class EgressProjectsReconcileJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  fixtures :instances, :users, :instance_roles, :projects

  setup { skip_unless_clickhouse! }

  test "adds missing projects and removes stale ones" do
    EventDestination.create!(project: projects(:one), name: "w", kind: "webhook", settings: { "url" => "https://h.example.com" })
    token = EventStreamToken.new(project: projects(:one_test), name: "pull")
    token.generate_token
    token.save!
    EventStream::Outbox.enable_project!(projects(:two).id)

    EgressProjectsReconcileJob.new.perform

    ids = EventStream::Outbox.enabled_project_ids
    assert_includes ids, projects(:one).id
    assert_includes ids, projects(:one_test).id
    assert_not_includes ids, projects(:two).id
  end
end
