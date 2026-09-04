# frozen_string_literal: true

require 'test_helper'

class Analytics::UserAttributeFilterTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @now = Time.current

    insert_ch_events([
      { event_id: 'evt_ua_premium', project_id: @project.id, event_type: 'VIEW', event_name: 'home',
        sdk_attributes: { 'plan' => 'premium', 'age_group' => '25-34' },
        properties: { 'plan' => 'event_prop_plan' },
        created_at: ts(1.hour) },
      { event_id: 'evt_ua_free', project_id: @project.id, event_type: 'OPEN', event_name: 'profile',
        sdk_attributes: { 'plan' => 'free' },
        created_at: ts(2.hours) },
      { event_id: 'evt_ua_none', project_id: @project.id, event_type: 'OPEN', event_name: 'bare',
        created_at: ts(3.hours) },
      { event_id: 'evt_ua_foreign', project_id: 99_999, event_type: 'VIEW',
        sdk_attributes: { 'plan' => 'premium' }, created_at: ts(1.hour) },
      { event_id: 'evt_ua_old', project_id: @project.id, event_type: 'VIEW',
        sdk_attributes: { 'plan' => 'premium' }, created_at: ts(1.year) }
    ])
  end

  test 'user.plan is matches only events with that attribute value' do
    assert_equal ['evt_ua_premium'], event_ids(query('user.plan', 'is', 'premium'))
  end

  test 'user.plan is_not excludes matching events, includes attribute-less events' do
    ids = event_ids(query('user.plan', 'is_not', 'premium'))
    assert_includes ids, 'evt_ua_free'
    assert_includes ids, 'evt_ua_none'
    assert_not_includes ids, 'evt_ua_premium'
  end

  test 'user.plan contains matches substring' do
    assert_equal ['evt_ua_premium'], event_ids(query('user.plan', 'contains', 'prem'))
  end

  test 'user.plan is with array matches any value' do
    ids = event_ids(query('user.plan', 'is', %w[premium free]))
    assert_equal %w[evt_ua_free evt_ua_premium], ids
  end

  test 'user attributes and event properties are separate namespaces' do
    assert_equal ['evt_ua_premium'], event_ids(query('plan', 'is', 'event_prop_plan'))
    assert_equal [], event_ids(query('user.plan', 'is', 'event_prop_plan'))
  end

  test 'user filter coexists with attribute filter' do
    result = Analytics::EventsQueryService.list(
      @project.id, start_date: 7.days.ago.to_date, end_date: Date.current,
      filters: [
        { 'field' => 'user.plan', 'operator' => 'is', 'value' => 'free' },
        { 'field' => 'event_type', 'operator' => 'is', 'value' => 'OPEN' }
      ]
    )
    assert_equal ['evt_ua_free'], event_ids(result)
  end

  test 'injection-shaped user key is rejected and clause skipped' do
    ids = event_ids(query('user.evil`key', 'is', 'x'))
    assert_equal %w[evt_ua_free evt_ua_none evt_ua_premium], ids
  end

  test 'empty user key is skipped' do
    ids = event_ids(query('user.', 'is', 'x'))
    assert_equal %w[evt_ua_free evt_ua_none evt_ua_premium], ids
  end

  test 'volume respects user attribute filter' do
    result = Analytics::EventsQueryService.volume(
      @project.id, start_date: 7.days.ago.to_date, end_date: Date.current,
      filters: [{ 'field' => 'user.plan', 'operator' => 'is', 'value' => 'premium' }]
    )
    assert_equal 1, result[:buckets].sum { |b| b['count'].to_i }
  end

  test 'field_values returns distinct user attribute values with typeahead' do
    result = Analytics::EventsQueryService.field_values(
      @project.id, field: 'user.plan', start_date: 7.days.ago.to_date, end_date: Date.current
    )
    assert_equal %w[free premium], result[:values].sort

    typed = Analytics::EventsQueryService.field_values(
      @project.id, field: 'user.plan', q: 'pre', start_date: 7.days.ago.to_date, end_date: Date.current
    )
    assert_equal ['premium'], typed[:values]
  end

  test 'fields picker offers user attribute keys prefixed and typed, filterable only' do
    insert_ch_events([{
      event_id: 'evt_ua_badkey', project_id: @project.id, event_type: 'VIEW',
      sdk_attributes: { 'good_key' => 'v', 'with space' => 'v' },
      created_at: ts(10.minutes)
    }])

    fields = Analytics::EventsQueryService.fields(
      @project.id, start_date: 7.days.ago.to_date, end_date: Date.current
    )[:fields]
    user_fields = fields.select { |f| f[:type] == 'user_attribute' }.map { |f| f[:name] }

    assert_includes user_fields, 'user.plan'
    assert_includes user_fields, 'user.age_group'
    assert_includes user_fields, 'user.good_key'
    assert_not_includes user_fields, 'user.with space'
    assert(fields.none? { |f| f[:type] == 'property' && f[:name].start_with?('user.') },
           'user attribute keys must not leak into the property list')
  end

  test 'pipeline-written events are searchable by user attribute end-to-end' do
    original = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    job = BatchEventProcessorJob.new
    job.jid = "ua-e2e-#{SecureRandom.hex(4)}"

    event_json = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: devices(:ios_device).id,
      data: nil, link_id: nil, engagement_time: nil, event_name: 'ua_search_e2e',
      created_at: 1.hour.from_now.iso8601
    }.to_json
    job.send(:process_batch, [event_json])

    hit = Analytics::EventsQueryService.list(
      @project.id, start_date: Date.current, end_date: Date.current + 2,
      filters: [{ 'field' => 'user.plan', 'operator' => 'is', 'value' => 'premium' },
                { 'field' => 'event_name', 'operator' => 'is', 'value' => 'ua_search_e2e' }]
    )
    assert_equal ['ua_search_e2e'], hit[:data].map { |e| e['event_name'] }

    miss = Analytics::EventsQueryService.list(
      @project.id, start_date: Date.current, end_date: Date.current + 2,
      filters: [{ 'field' => 'user.plan', 'operator' => 'is', 'value' => 'enterprise' },
                { 'field' => 'event_name', 'operator' => 'is', 'value' => 'ua_search_e2e' }]
    )
    assert_equal [], miss[:data]
  ensure
    Rails.application.config.clickhouse_write_enabled = original
    if job
      REDIS.with do |conn|
        conn.del("events:processing:#{job.jid}", "events:heartbeat:#{job.jid}")
        keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
        conn.del(*keys) if keys.any?
      end
    end
  end

  private

  def ts(ago)
    (@now - ago).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
  end

  def query(field, operator, value)
    Analytics::EventsQueryService.list(
      @project.id, start_date: 7.days.ago.to_date, end_date: Date.current,
      filters: [{ 'field' => field, 'operator' => operator, 'value' => value }]
    )
  end

  def event_ids(result)
    result[:data].map { |e| e['event_id'] }.sort
  end
end
