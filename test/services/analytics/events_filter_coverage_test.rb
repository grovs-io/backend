# frozen_string_literal: true

require 'test_helper'

class Analytics::EventsFilterCoverageTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  # --- Field config ---

  STRING_FIELDS = {
    'event_type'         => { a: 'VIEW',           b: 'OPEN',            contains: 'view' },
    'event_name'         => { a: 'home_viewed',    b: 'profile_opened',  contains: 'home' },
    'screen_name'        => { a: 'HomeScreen',     b: 'ProfileScreen',   contains: 'home' },
    'platform'           => { a: 'ios',            b: 'android',         contains: 'ios' },
    'app_version'        => { a: '2.1.0',          b: '3.0.0',           contains: '2.1' },
    'country'            => { a: 'US',             b: 'DE',              contains: 'us' },
    'city'               => { a: 'New York',       b: 'Berlin',          contains: 'new' },
    'device_model'       => { a: 'iPhone 14',      b: 'Pixel 8',        contains: 'iphone' },
    'os'                 => { a: 'iOS',            b: 'Android',         contains: 'ios' },
    'os_version'         => { a: '17.2',           b: '14.0',            contains: '17' },
    'session_id'         => { a: 'sess_001',       b: 'sess_002',        contains: '001' }
  }.freeze

  INTEGER_FIELDS = {
    'visitor_id'   => { a: 11_001, b: 11_002 },
    'link_id'      => { a: 501,    b: 502 },
    'campaign_id'  => { a: 201,    b: 202 }
  }.freeze

  # --- Setup ---

  setup do
    skip_unless_clickhouse!
    # events is MergeTree (no dedup): without a clean slate, every test's setup
    # re-inserts evt_filter_A/B/C/D as duplicates and per-test rows leak into
    # later tests (the injection test's "only mine/evt_filter rows" assertion is
    # order-sensitive). Truncate so each test sees exactly the data it inserts.
    truncate_clickhouse_tables
    @project = projects(:one)
    @now = Time.current

    event_a = {
      event_id: 'evt_filter_A',
      project_id: @project.id,
      event_type: 'VIEW',
      event_name: 'home_viewed',
      screen_name: 'HomeScreen',
      platform: 'ios',
      app_version: '2.1.0',
      country: 'US',
      city: 'New York',
      device_model: 'iPhone 14',
      os: 'iOS',
      os_version: '17.2',
      session_id: 'sess_001',
      visitor_id: 11_001,
      link_id: 501,
      campaign_id: 201,
      created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }

    event_b = {
      event_id: 'evt_filter_B',
      project_id: @project.id,
      event_type: 'OPEN',
      event_name: 'profile_opened',
      screen_name: 'ProfileScreen',
      platform: 'android',
      app_version: '3.0.0',
      country: 'DE',
      city: 'Berlin',
      device_model: 'Pixel 8',
      os: 'Android',
      os_version: '14.0',
      session_id: 'sess_002',
      visitor_id: 11_002,
      link_id: 502,
      campaign_id: 202,
      created_at: (@now - 2.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }

    # Decoy: same values as A but different project — must never appear
    event_c = event_a.merge(
      event_id: 'evt_filter_C',
      project_id: 99_999
    )

    # Decoy: same project as A but created_at 1 year ago — outside date range
    event_d = event_a.merge(
      event_id: 'evt_filter_D',
      created_at: (@now - 1.year).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    )

    insert_ch_events([event_a, event_b, event_c, event_d])
  end

  # --- String field tests (16 fields x 3 operators = 48 tests) ---

  STRING_FIELDS.each do |field, vals|
    test "filter #{field} is returns only matching event" do
      result = query_with_filter(field, 'is', vals[:a])
      assert_equal ['evt_filter_A'], event_ids(result)
    end

    test "filter #{field} is_not excludes matching event" do
      result = query_with_filter(field, 'is_not', vals[:a])
      assert_equal ['evt_filter_B'], event_ids(result)
    end

    test "filter #{field} contains matches substring" do
      result = query_with_filter(field, 'contains', vals[:contains])
      ids = event_ids(result)
      assert_includes ids, 'evt_filter_A'
      assert_not_includes ids, 'evt_filter_B'
    end
  end

  # --- Integer field tests (3 fields x 2 operators = 6 tests) ---

  INTEGER_FIELDS.each do |field, vals|
    test "filter #{field} is returns only matching event" do
      result = query_with_filter(field, 'is', vals[:a])
      assert_equal ['evt_filter_A'], event_ids(result)
    end

    test "filter #{field} is_not excludes matching event" do
      result = query_with_filter(field, 'is_not', vals[:a])
      assert_equal ['evt_filter_B'], event_ids(result)
    end
  end

  # --- JSON property filter regression tests ---
  # These verify the refactor didn't break dynamic property filtering.
  # Standard fields now route through QueryHelpers; property fields must
  # still route through build_property_filter via a native JSON subcolumn cast.

  test 'property filter is returns matching event' do
    insert_property_events
    result = query_with_filter('my_prop', 'is', 'hello')
    assert_equal ['evt_prop_match'], event_ids(result)
  end

  test 'property filter is_not excludes matching event' do
    insert_property_events
    result = query_with_filter('my_prop', 'is_not', 'hello')
    ids = event_ids(result)
    assert_includes ids, 'evt_prop_other'
    assert_not_includes ids, 'evt_prop_match'
  end

  test 'property filter contains matches substring' do
    insert_property_events
    result = query_with_filter('my_prop', 'contains', 'hell')
    ids = event_ids(result)
    assert_includes ids, 'evt_prop_match'
    assert_not_includes ids, 'evt_prop_other'
  end

  test 'property filter is with array returns matching events' do
    insert_property_events
    result = query_with_filter('my_prop', 'is', %w[hello world])
    ids = event_ids(result)
    assert_includes ids, 'evt_prop_match'
    assert_includes ids, 'evt_prop_other'
  end

  test 'property filter with injection-shaped key is rejected' do
    insert_property_events
    # Field name contains a space, which valid_property_key? rejects (the widened
    # allowlist still bans space/backtick/control chars) so the clause is skipped.
    result = query_with_filter("'); DROP TABLE--", 'is', 'x')
    ids = event_ids(result)
    # Invalid property key is silently skipped, but must not escape project/date scope.
    assert_includes ids, 'evt_filter_A'
    assert_includes ids, 'evt_filter_B'
    assert_not_includes ids, 'evt_filter_C'
    assert_not_includes ids, 'evt_filter_D'
  end

  # SECURITY REGRESSION (cross-tenant SQL injection via property-key backslash).
  # A property key ending in backslash escapes the template's closing backtick in
  # CAST(properties.`#{field}` AS String); the attacker then supplies the next
  # backtick in the (un-backtick-escaped) filter VALUE and breaks out into raw SQL,
  # e.g. `OR project_id = 999`, defeating tenant scoping. This exercises the REAL
  # query path through REAL ClickHouse. With backslash rejected, the filter is
  # skipped (col_expr nil) and the result stays scoped to the caller's project.
  test 'backslash property key cannot escape tenant scope (real ClickHouse)' do
    # Seed the caller's own row and a foreign-tenant secret row in project 999
    # (the exact id the exploit payload targets via `OR project_id = 999`).
    insert_ch_events([
      { event_id: 'mine', project_id: @project.id, event_type: 'VIEW',
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { event_id: 'secret', project_id: 999, event_type: 'VIEW',
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    malicious_field = 'x\\' # one backslash -> escapes the closing backtick
    malicious_value = '` AS String) IS NOT NULL OR project_id = 999 -- '

    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => malicious_field, 'operator' => 'is', 'value' => malicious_value }]
    )
    ids = event_ids(result)

    assert_not_includes ids, 'secret',
                        'foreign-tenant row leaked -- backslash escaped the identifier quoting'
    assert_includes ids, 'mine',
                    'caller-scoped row missing -- exploit produced a CH syntax error (still a vuln)'
    assert(ids.all? { |id| %w[mine].include?(id) || id.start_with?('evt_filter') },
           "result contained an unexpected (cross-tenant) row: #{ids.inspect}")
  end

  # SECURITY REGRESSION (C): a malicious backslash key into field_values must return
  # an empty value set (col_expr nil -> early return) and never leak/raise.
  test 'field_values with backslash key returns empty and does not leak (real ClickHouse)' do
    insert_ch_events([
      { event_id: 'secret', project_id: 999, event_type: 'VIEW',
        properties: { 'x' => 'leak' },
        created_at: (@now - 1.hour).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    result = Analytics::EventsQueryService.field_values(
      @project.id, field: 'x\\',
      start_date: 7.days.ago.to_date, end_date: Date.current
    )
    assert_equal({ values: [] }, result)
  end

  test 'string filter treats SQL-looking values as escaped literals' do
    result = query_with_filter('platform', 'is', "ios' OR '1'='1")
    assert_equal [], event_ids(result)
  end

  test 'property filter treats SQL-looking values as escaped literals' do
    insert_property_events
    result = query_with_filter('my_prop', 'is', "hello' OR '1'='1")
    assert_equal [], event_ids(result)
  end

  test 'property filter coexists with standard field filter' do
    insert_property_events
    # Combine a standard attribute filter AND a property filter
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [
        { 'field' => 'event_type', 'operator' => 'is', 'value' => 'VIEW' },
        { 'field' => 'my_prop', 'operator' => 'is', 'value' => 'hello' }
      ]
    )
    ids = event_ids(result)
    # Only evt_prop_match has event_type=VIEW AND my_prop=hello
    assert_equal ['evt_prop_match'], ids
  end

  # --- Edge cases ---

  test 'invalid field name is silently skipped and returns all rows' do
    # 'bad key' has a space, which the widened allowlist (valid_property_key?)
    # still rejects, so field_column_expression returns nil and the filter is
    # skipped -- every in-scope row is returned. (A non-identifier key like
    # '!!!bad' is now a *valid* filterable key, so it would no longer be skipped.)
    result = query_with_filter('bad key', 'is', 'anything')
    ids = event_ids(result)
    assert_includes ids, 'evt_filter_A'
    assert_includes ids, 'evt_filter_B'
  end

  test 'shorthand keys f/o/v work same as field/operator/value' do
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'f' => 'event_type', 'o' => 'is', 'v' => 'VIEW' }]
    )
    assert_equal ['evt_filter_A'], event_ids(result)
  end

  test 'contains on integer field visitor_id is silently skipped and returns all rows' do
    result = query_with_filter('visitor_id', 'contains', '11001')
    ids = event_ids(result)
    assert_includes ids, 'evt_filter_A'
    assert_includes ids, 'evt_filter_B'
  end

  test 'array values for is operator work on string field' do
    result = query_with_filter('event_type', 'is', %w[VIEW OPEN])
    ids = event_ids(result)
    assert_includes ids, 'evt_filter_A'
    assert_includes ids, 'evt_filter_B'
  end

  test 'array values for is operator work on integer field' do
    result = query_with_filter('visitor_id', 'is', [11_001, 11_002])
    ids = event_ids(result)
    assert_includes ids, 'evt_filter_A'
    assert_includes ids, 'evt_filter_B'
  end

  # --- Native JSON subcolumn parity (Task 8) ---
  # Proves CAST(properties.`k` AS String) is a faithful drop-in for the old
  # JSONExtractString(properties,'k') across every key class, against REAL CH.
  # For each key we assert: (1) SQL-level parity -- a raw query using the CAST
  # subcolumn returns the SAME event_ids as one using JSONExtractString over the
  # identical scope; and (2) end-to-end the service's filter path returns that
  # same set. This is the picker-vs-filter legitimacy test.

  PARITY_KEYS = {
    'plan'    => 'pro',   # plain identifier
    'a.b'     => 'x',     # nested object -> flattened leaf path a.b
    'user-id' => 'u42',   # hyphen (rejected by the old narrow regex)
    '2fa'     => 'on',    # leading digit
    '$set'    => 'yes'    # leading '$'
  }.freeze

  test 'CAST subcolumn matches JSONExtractString row-for-row across key classes' do
    insert_parity_events

    PARITY_KEYS.each do |key, val|
      cast = "CAST(properties.`#{key}` AS String)"
      ext  = "JSONExtractString(properties, '#{key}')"

      # (1) is: equality. CAST set == JSONExtractString set == service set.
      via_cast = ids_raw(cast, '=', val)
      via_ext  = ids_raw(ext, '=', val)
      via_svc  = event_ids(query_with_filter(key, 'is', val))
      assert_equal via_ext, via_cast, "is parity broke for #{key}"
      assert_equal via_ext, via_svc, "service 'is' diverged from JSONExtractString for #{key}"
      assert_equal ['parity_match'], via_svc, "expected only parity_match for #{key}=#{val}"

      # (2) is_not: inequality (missing-key rows have '' so they are included).
      not_cast = ids_raw(cast, '!=', val)
      not_ext  = ids_raw(ext, '!=', val)
      not_svc  = event_ids(query_with_filter(key, 'is_not', val))
      assert_equal not_ext, not_cast, "is_not parity broke for #{key}"
      assert_equal not_ext, not_svc, "service 'is_not' diverged from JSONExtractString for #{key}"
      assert_not_includes not_svc, 'parity_match', "is_not must exclude the matching row for #{key}"
    end
  end

  # Parity for NON-string property values (numbers, booleans). Proves the CAST
  # subcolumn drop-in matches JSONExtractString for count=5 / flag=true, not just
  # strings -- against REAL ClickHouse.
  test 'CAST subcolumn matches JSONExtractString for numeric and boolean values' do
    insert_ch_events([
      { event_id: 'nonstr', project_id: @project.id, event_type: 'VIEW',
        properties: { 'count' => 5, 'flag' => true },
        created_at: (@now - 15.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    %w[count flag].each do |key|
      cast_val = Clickhouse.with do |c|
        c.select_value("SELECT CAST(properties.`#{key}` AS String) FROM events " \
                       "WHERE project_id = #{@project.id} AND event_id = 'nonstr'")
      end
      ext_val = Clickhouse.with do |c|
        c.select_value("SELECT JSONExtractString(properties, '#{key}') FROM events " \
                       "WHERE project_id = #{@project.id} AND event_id = 'nonstr'")
      end
      assert_equal ext_val, cast_val, "non-string parity broke for #{key}"
    end
  end

  test 'missing key yields empty string identically through both paths' do
    insert_parity_events

    # No event has a 'plan' value except parity_match -> every other in-scope row
    # reads ''. field='' (is '') and field!='nonsense' must agree across paths.
    cast = 'CAST(properties.`plan` AS String)'
    ext  = "JSONExtractString(properties, 'plan')"

    empties_cast = ids_raw(cast, '=', '')
    empties_ext  = ids_raw(ext, '=', '')
    empties_svc  = event_ids(query_with_filter('plan', 'is', ''))

    assert_equal empties_ext, empties_cast, 'missing-key = parity broke'
    assert_equal empties_ext, empties_svc, "service missing-key '' diverged from JSONExtractString"
    assert_not_includes empties_svc, 'parity_match', 'the row with plan=pro must not read as empty'
    # The known missing-key rows are present (proves it is not vacuously empty).
    assert_includes empties_svc, 'parity_other'

    # field != 'nonsense' returns the SAME rows as field = '' here (all rows read
    # '' except parity_match, which is also != 'nonsense'): both include everyone.
    not_nonsense = event_ids(query_with_filter('plan', 'is_not', 'nonsense'))
    assert_includes not_nonsense, 'parity_match'
    assert_includes not_nonsense, 'parity_other'
  end

  test 'field_values typeahead reads distinct values via the subcolumn path' do
    insert_parity_events

    # Plain key.
    plan_vals = Analytics::EventsQueryService.field_values(
      @project.id, field: 'plan',
      start_date: 7.days.ago.to_date, end_date: Date.current
    )[:values]
    assert_equal ['pro'], plan_vals

    # Non-identifier key routes through the same CAST subcolumn path.
    uid_vals = Analytics::EventsQueryService.field_values(
      @project.id, field: 'user-id',
      start_date: 7.days.ago.to_date, end_date: Date.current
    )[:values]
    assert_equal ['u42'], uid_vals
  end

  # IN / is-array parity: CAST(properties.`plan`) IN (...) must select the same
  # rows as JSONExtractString(properties,'plan') IN (...), against REAL CH, both
  # for the positive (IN) and negative (NOT IN) membership tests. The reference
  # set is computed with a DIFFERENT SQL function (JSONExtractString) than the
  # service path (CAST subcolumn), so equality here proves drop-in parity rather
  # than a tautology -- if CAST emitted a different string representation for any
  # value the two sets would diverge and these asserts would fail.
  test 'CAST subcolumn IN matches JSONExtractString IN row-for-row (array is/is_not)' do
    insert_plan_events(
      'plan_pro'        => { 'plan' => 'pro' },
      'plan_free'       => { 'plan' => 'free' },
      'plan_enterprise' => { 'plan' => 'enterprise' },
      'plan_missing'    => { 'other' => 'thing' } # no plan key -> reads ''
    )

    set = "('pro', 'enterprise')"

    # --- IN ('pro','enterprise') ---
    in_cast = ids_pred("CAST(properties.`plan` AS String) IN #{set}")
    in_ext  = ids_pred("JSONExtractString(properties, 'plan') IN #{set}")
    in_svc  = event_ids(query_with_filter('plan', 'is', %w[pro enterprise]))

    assert_equal in_ext, in_cast, 'IN parity broke (CAST vs JSONExtractString)'
    assert_equal in_ext, in_svc, "service 'is' array diverged from JSONExtractString IN"
    # Concrete: exactly the two membership rows, nothing else (proves it is a real
    # filter, not a pass-through that returns every scoped row).
    assert_equal %w[plan_enterprise plan_pro], in_svc

    # --- NOT IN ('pro','enterprise') ---
    not_cast = ids_pred("CAST(properties.`plan` AS String) NOT IN #{set}")
    not_ext  = ids_pred("JSONExtractString(properties, 'plan') NOT IN #{set}")
    not_svc  = event_ids(query_with_filter('plan', 'is_not', %w[pro enterprise]))

    assert_equal not_ext, not_cast, 'NOT IN parity broke (CAST vs JSONExtractString)'
    assert_equal not_ext, not_svc, "service 'is_not' array diverged from JSONExtractString NOT IN"
    # free and the missing-key row (reads '') are NOT IN the set -> included;
    # the two membership rows are excluded.
    assert_includes not_svc, 'plan_free'
    assert_includes not_svc, 'plan_missing'
    assert_not_includes not_svc, 'plan_pro'
    assert_not_includes not_svc, 'plan_enterprise'
  end

  # LIKE / contains parity: lower(CAST(properties.`plan`)) LIKE '%pro%' must select
  # the same rows as lower(JSONExtractString(properties,'plan')) LIKE '%pro%',
  # against REAL CH. Substring values ('pro-monthly','pro-annual','free-tier')
  # ensure the match is a genuine contains, not equality. Reference uses a
  # different extraction function than the service path -> real parity, not a
  # self-comparison.
  test 'CAST subcolumn LIKE matches JSONExtractString LIKE row-for-row (contains)' do
    insert_plan_events(
      'plan_pro_monthly' => { 'plan' => 'pro-monthly' },
      'plan_pro_annual'  => { 'plan' => 'pro-annual' },
      'plan_free_tier'   => { 'plan' => 'free-tier' }
    )

    like_cast = ids_pred("lower(CAST(properties.`plan` AS String)) LIKE '%pro%'")
    like_ext  = ids_pred("lower(JSONExtractString(properties, 'plan')) LIKE '%pro%'")
    like_svc  = event_ids(query_with_filter('plan', 'contains', 'pro'))

    assert_equal like_ext, like_cast, 'LIKE parity broke (CAST vs JSONExtractString)'
    assert_equal like_ext, like_svc, "service 'contains' diverged from JSONExtractString LIKE"
    # Concrete: the two 'pro-*' rows match; 'free-tier' (and the property-less
    # setup rows, which read '') do not.
    assert_equal %w[plan_pro_annual plan_pro_monthly], like_svc
    assert_not_includes like_svc, 'plan_free_tier'
  end

  test 'fields picker only offers keys that valid_property_key? accepts' do
    # 'good_key' is filterable; 'with space' is surfaced by JSONAllPaths but must
    # be filtered out so the picker set == the filterable set.
    insert_ch_events([{
      event_id: 'evt_fields_align', project_id: @project.id, event_type: 'VIEW',
      properties: { 'good_key' => 'v', 'with space' => 'v' },
      created_at: (@now - 10.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    }])

    names = Analytics::EventsQueryService.fields(
      @project.id, start_date: 7.days.ago.to_date, end_date: Date.current
    )[:fields].select { |f| f[:type] == 'property' }.map { |f| f[:name] }

    assert_includes names, 'good_key'
    assert_not_includes names, 'with space',
                         'an unfilterable key must never reach the picker'
    assert names.all? { |n| Analytics::EventsQueryService.valid_property_key?(n) },
           'every offered property key must pass valid_property_key?'
  end

  private

  # Reference / parity-target raw query over the same scope list() uses
  # (project_id + toDate(created_at) window). col_expr is test-controlled SQL.
  def ids_raw(col_expr, oper, value)
    esc = value.to_s.gsub("'", "''")
    sql = "SELECT event_id FROM events WHERE project_id = #{@project.id} " \
          "AND toDate(created_at) >= '#{7.days.ago.to_date}' " \
          "AND toDate(created_at) <= '#{Date.current}' " \
          "AND #{col_expr} #{oper} '#{esc}' ORDER BY event_id"
    Clickhouse.with { |c| c.select_all(sql) }.map { |r| r['event_id'] }.sort
  end

  # Like ids_raw but takes a full boolean predicate (so IN(...) / NOT IN(...) /
  # LIKE patterns can be expressed) over the identical project+date scope list()
  # uses. The predicate is test-controlled SQL.
  def ids_pred(predicate)
    sql = "SELECT event_id FROM events WHERE project_id = #{@project.id} " \
          "AND toDate(created_at) >= '#{7.days.ago.to_date}' " \
          "AND toDate(created_at) <= '#{Date.current}' " \
          "AND #{predicate} ORDER BY event_id"
    Clickhouse.with { |c| c.select_all(sql) }.map { |r| r['event_id'] }.sort
  end

  def insert_plan_events(rows)
    base_ts = (@now - 12.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events(rows.map do |id, props|
      { event_id: id, project_id: @project.id, event_type: 'VIEW',
        properties: props, created_at: base_ts }
    end)
  end

  def insert_parity_events
    base_ts = (@now - 20.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_events([
      { event_id: 'parity_match', project_id: @project.id, event_type: 'VIEW',
        properties: { 'plan' => 'pro', 'a' => { 'b' => 'x' }, 'user-id' => 'u42',
                      '2fa' => 'on', '$set' => 'yes' },
        created_at: base_ts },
      { event_id: 'parity_other', project_id: @project.id, event_type: 'OPEN',
        properties: { 'unrelated' => 'thing' },
        created_at: base_ts }
    ])
  end

  def query_with_filter(field, operator, value)
    Analytics::EventsQueryService.list(
      @project.id,
      start_date: 7.days.ago.to_date,
      end_date: Date.current,
      filters: [{ 'field' => field, 'operator' => operator, 'value' => value }]
    )
  end

  def event_ids(result)
    result[:data].map { |e| e['event_id'] }.sort
  end

  def insert_property_events
    insert_ch_events([
      {
        event_id: 'evt_prop_match',
        project_id: @project.id,
        event_type: 'VIEW',
        event_name: 'prop_test',
        properties: { 'my_prop' => 'hello' },
        created_at: (@now - 30.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      },
      {
        event_id: 'evt_prop_other',
        project_id: @project.id,
        event_type: 'OPEN',
        event_name: 'prop_test_2',
        properties: { 'my_prop' => 'world' },
        created_at: (@now - 45.minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    ])
  end
end
