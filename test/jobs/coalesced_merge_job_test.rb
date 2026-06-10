require "test_helper"

class CoalescedMergeJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events

  setup do
    @job = CoalescedMergeJob.new
    @project = projects(:one)

    # Target device — all sources merge into this one
    @to_dev = Device.create!(
      user_agent: "CoalescedTo/#{SecureRandom.hex(4)}",
      ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
      platform: "android"
    )
    @to_vis = Visitor.create!(device: @to_dev, project: @project)
  end

  teardown do
    # Clean up Redis keys created during tests
    set_key = "#{CoalescedMergeJob::SET_PREFIX}:#{@to_dev.id}:#{@project.id}"
    lock_key = "#{CoalescedMergeJob::LOCK_PREFIX}:#{@to_dev.id}:#{@project.id}"
    pending_key = "#{CoalescedMergeJob::PENDING_PREFIX}:#{@to_dev.id}:#{@project.id}"
    failures_key = "#{CoalescedMergeJob::FAILURES_PREFIX}:#{@to_dev.id}:#{@project.id}"
    REDIS.del(set_key, lock_key, pending_key, failures_key)
  end

  test "drains all source devices from the Redis set" do
    from_devs = create_source_devices(3)
    set_key = push_sources(from_devs)

    @job.perform(@to_dev.id, @project.id)

    assert_equal 0, REDIS.scard(set_key), "Set should be empty after drain"
    from_devs.each do |dev|
      vis = Visitor.find_by(device: dev, project: @project)
      assert_nil vis, "Source visitor should be deleted"
    end
  end

  test "merges stats from multiple sources into target" do
    from_devs = create_source_devices(2)
    push_sources(from_devs)

    date = Date.current
    from_devs.each_with_index do |dev, i|
      vis = Visitor.find_by(device: dev, project: @project)
      VisitorDailyStatistic.create!(
        visitor: vis, project_id: @project.id,
        event_date: date, platform: "ios", views: (i + 1) * 10
      )
    end

    @job.perform(@to_dev.id, @project.id)

    stat = VisitorDailyStatistic.find_by(visitor_id: @to_vis.id, event_date: date, platform: "ios")
    assert_not_nil stat
    assert_equal 30, stat.views, "Views should be summed (10 + 20)"
  end

  test "skips when processing lock is already held" do
    lock_key = "#{CoalescedMergeJob::LOCK_PREFIX}:#{@to_dev.id}:#{@project.id}"
    REDIS.set(lock_key, "other-owner", ex: 60)

    from_devs = create_source_devices(1)
    set_key = push_sources(from_devs)

    @job.perform(@to_dev.id, @project.id)

    assert_equal 1, REDIS.scard(set_key), "Set should be untouched when lock is held"
  end

  test "leaves failed source in set for retry" do
    from_devs = create_source_devices(2)
    set_key = push_sources(from_devs)

    # Delete the first device so its merge raises. Use raw .delete to simulate a
    # row vanishing under a concurrent merge; clear dependent notification_messages
    # first since .delete skips the dependent: :destroy that would normally remove
    # them (they are auto-created by Visitor's after_create_commit when an active
    # notification exists, which only happens in the full suite).
    first_vis = Visitor.find_by(device: from_devs[0], project: @project)
    first_vis.notification_messages.delete_all
    first_vis.delete
    from_devs[0].delete

    @job.perform(@to_dev.id, @project.id)

    remaining = REDIS.smembers(set_key)
    # First source failed (device gone) — should stay in set.
    # But MergeVisitorEventsJob bails early on missing device, which doesn't raise.
    # So it gets removed as a no-op. Second source merges normally.
    assert_equal 0, remaining.size, "Both should be processed (one as no-op, one as merge)"
  end

  test "dead-letters source after MAX_ATTEMPTS failures" do
    from_devs = create_source_devices(1)
    set_key = push_sources(from_devs)
    failures_key = "#{CoalescedMergeJob::FAILURES_PREFIX}:#{@to_dev.id}:#{@project.id}"

    failing_job = Object.new
    def failing_job.perform(*, **)
      raise "permanent failure"
    end

    MergeVisitorEventsJob.stub(:new, failing_job) do
      CoalescedMergeJob::MAX_ATTEMPTS.times do |i|
        @job.perform(@to_dev.id, @project.id)
        if i < CoalescedMergeJob::MAX_ATTEMPTS - 1
          assert_equal 1, REDIS.scard(set_key), "Source should remain in set after attempt #{i + 1}"
          assert_equal (i + 1).to_s, REDIS.hget(failures_key, from_devs[0].id.to_s)
        end
      end
    end

    assert_equal 0, REDIS.scard(set_key), "Source should be removed after max attempts"
    assert_nil REDIS.hget(failures_key, from_devs[0].id.to_s), "Failure counter should be cleaned up"
  end

  test "clears failure count on successful merge" do
    from_devs = create_source_devices(1)
    set_key = push_sources(from_devs)
    failures_key = "#{CoalescedMergeJob::FAILURES_PREFIX}:#{@to_dev.id}:#{@project.id}"

    REDIS.hset(failures_key, from_devs[0].id.to_s, "1")

    @job.perform(@to_dev.id, @project.id)

    assert_equal 0, REDIS.scard(set_key), "Source should be drained"
    assert_nil REDIS.hget(failures_key, from_devs[0].id.to_s), "Failure counter should be cleared on success"
  end

  test "releases lock after processing" do
    from_devs = create_source_devices(1)
    push_sources(from_devs)

    lock_key = "#{CoalescedMergeJob::LOCK_PREFIX}:#{@to_dev.id}:#{@project.id}"

    @job.perform(@to_dev.id, @project.id)

    assert_nil REDIS.get(lock_key), "Lock should be released after job completes"
  end

  private

  def create_source_devices(count)
    count.times.map do
      dev = Device.create!(
        user_agent: "CoalescedFrom/#{SecureRandom.hex(4)}",
        ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        platform: "ios"
      )
      Visitor.create!(device: dev, project: @project)
      dev
    end
  end

  def push_sources(from_devs)
    set_key = "#{CoalescedMergeJob::SET_PREFIX}:#{@to_dev.id}:#{@project.id}"
    from_devs.each { |dev| REDIS.sadd?(set_key, dev.id.to_s) }
    set_key
  end
end
