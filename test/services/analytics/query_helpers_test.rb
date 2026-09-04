# frozen_string_literal: true

require 'test_helper'

# QueryHelpers methods are private — test via a disposable wrapper.
class Analytics::QueryHelpersTest < ActiveSupport::TestCase
  # Thin test class that exposes QueryHelpers as public methods.
  class Harness
    extend Analytics::QueryHelpers

    # Make private methods public for testing.
    class << self
      public :sanitize_string, :sanitize_date, :sanitize_date_value,
             :sanitize_like, :platform_where, :parse_filters,
             :build_filter_clauses, :log_query_failure,
             :format_number, :format_duration_ms, :display_source_name,
             :safe_percent, :source_type_expr, :source_where_clause,
             :resolve_id_field, :resolve_visitor_field, :ch_id_set
    end
  end

  # ── sanitize_string ──────────────────────────────────────────────────

  test 'parse_filters caps the number of filters at MAX_FILTERS' do
    many = Array.new(100) { |i| { 'field' => 'platform', 'operator' => 'is', 'value' => "v#{i}" } }
    assert_equal Analytics::QueryHelpers::MAX_FILTERS, Harness.parse_filters(many).size
  end

  # Real clients send a field=>value map instead of the documented array; that used to
  # iterate as [key, value] pairs and TypeError into a 500.
  test 'parse_filters reads an object of field => value as equality filters' do
    parsed = Harness.parse_filters('{"link_id":"22420785","event_type":"reactivation"}')

    assert_equal([{ 'field' => 'link_id', 'operator' => 'is', 'value' => '22420785' },
                  { 'field' => 'event_type', 'operator' => 'is', 'value' => 'reactivation' }], parsed)
  end

  # Reading a lone filter object as the field=>value shorthand would name its own keys as
  # fields, drop them all, and quietly return unfiltered data.
  test 'parse_filters treats a single unwrapped filter object as one filter' do
    parsed = Harness.parse_filters('{"field":"link_id","operator":"is_not","value":"5"}')

    assert_equal([{ 'field' => 'link_id', 'operator' => 'is_not', 'value' => '5' }], parsed)
  end

  # Bracketed array params arrive as ActionController::Parameters, which is not a Hash.
  test 'parse_filters keeps array entries that are request parameters' do
    entry = ActionController::Parameters.new(field: 'platform', operator: 'is', value: 'ios')

    assert_equal([{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }],
                 Harness.parse_filters([entry]))
  end

  test 'parse_filters drops non-object entries instead of raising' do
    assert_equal [], Harness.parse_filters('["event_type", 3, null]')
    assert_equal [], Harness.parse_filters('"a string"')
    assert_equal [], Harness.parse_filters('null')
  end

  test 'build_filter_clauses caps IN(...) list length at MAX_FILTER_VALUES' do
    big = { 'field' => 'platform', 'operator' => 'is', 'value' => Array.new(500) { |i| "v#{i}" } }
    clauses = Harness.build_filter_clauses([big], allowed_fields: %w[platform])
    assert_equal Analytics::QueryHelpers::MAX_FILTER_VALUES, clauses.first.scan(/'v\d+'/).size
  end

  test 'sanitize_string: plain string unchanged' do
    assert_equal 'hello', Harness.sanitize_string('hello')
  end

  test 'sanitize_string: escapes single quotes' do
    assert_equal "it\\'s", Harness.sanitize_string("it's")
  end

  test 'sanitize_string: doubles backslashes' do
    assert_equal "path\\\\to", Harness.sanitize_string("path\\to")
  end

  test 'sanitize_string: escapes quotes even when backslash present' do
    assert_equal "a\\\\b\\'c", Harness.sanitize_string("a\\b'c")
  end

  test 'sanitize_string: backslash-quote injection neutralised' do
    # Input: \' should become \\' (escaped backslash + escaped quote)
    # so CH sees a literal backslash followed by a literal quote inside the string.
    assert_equal "\\\\\\'", Harness.sanitize_string("\\'")
  end

  test 'sanitize_string: converts non-string to string' do
    assert_equal '42', Harness.sanitize_string(42)
    assert_equal '', Harness.sanitize_string(nil)
  end

  test 'sanitize_string: escapes control characters used by ClickHouse string literals' do
    input = "a\0b\bc\nd\re\tf"

    assert_equal 'a\\0b\\bc\\nd\\re\\tf', Harness.sanitize_string(input)
  end

  test 'sanitize_string: empty string stays empty' do
    assert_equal '', Harness.sanitize_string('')
  end

  # ── sanitize_date ────────────────────────────────────────────────────

  test 'sanitize_date: valid ISO date returns formatted string' do
    assert_equal '2026-05-01', Harness.sanitize_date('2026-05-01')
  end

  test 'sanitize_date: valid date with different format parsed correctly' do
    assert_equal '2026-01-15', Harness.sanitize_date('January 15, 2026')
  end

  test 'sanitize_date: raises on invalid date string' do
    assert_raises(Date::Error) { Harness.sanitize_date('not-a-date') }
  end

  test 'sanitize_date: raises on empty string' do
    assert_raises(Date::Error) { Harness.sanitize_date('') }
  end

  test 'sanitize_date: converts Date object via to_s' do
    assert_equal '2026-03-10', Harness.sanitize_date(Date.new(2026, 3, 10))
  end

  # ── sanitize_date_value ──────────────────────────────────────────────

  test 'sanitize_date_value: Date object formatted without reparsing' do
    date = Date.new(2026, 5, 8)
    assert_equal '2026-05-08', Harness.sanitize_date_value(date)
  end

  test 'sanitize_date_value: Time object converted to date' do
    time = Time.utc(2026, 5, 8, 14, 30, 0)
    assert_equal '2026-05-08', Harness.sanitize_date_value(time)
  end

  test 'sanitize_date_value: ActiveSupport::TimeWithZone converted to date' do
    time = Time.utc(2026, 5, 8, 14, 30, 0).in_time_zone('US/Eastern')
    assert_equal '2026-05-08', Harness.sanitize_date_value(time)
  end

  test 'sanitize_date_value: string fallback uses Date.parse' do
    assert_equal '2026-05-01', Harness.sanitize_date_value('2026-05-01')
  end

  test 'sanitize_date_value: invalid string raises' do
    assert_raises(Date::Error) { Harness.sanitize_date_value('garbage') }
  end

  # ── sanitize_like ────────────────────────────────────────────────────

  test 'sanitize_like: escapes percent sign' do
    # Double backslash: \\% in Ruby string → \% after CH string parse → literal % for LIKE
    assert_equal '100\\\\%', Harness.sanitize_like('100%')
  end

  test 'sanitize_like: escapes underscore' do
    assert_equal 'col\\\\_name', Harness.sanitize_like('col_name')
  end

  test 'sanitize_like: also escapes quotes and backslashes (from sanitize_string)' do
    # Input: 50%\it's  →  escape wildcards: 50\%\it's  →  sanitize_string: 50\\%\\it\'s
    assert_equal "50\\\\%\\\\it\\'s", Harness.sanitize_like("50%\\it's")
  end

  test 'sanitize_like: plain string unchanged' do
    assert_equal 'hello', Harness.sanitize_like('hello')
  end

  # ── platform_where ──────────────────────────────────────────────────

  test 'platform_where: nil returns empty string' do
    assert_equal '', Harness.platform_where(nil)
  end

  test 'platform_where: blank returns empty string' do
    assert_equal '', Harness.platform_where('')
  end

  test 'platform_where: valid platform without table prefix' do
    assert_equal "AND if(platform IN ('ios', 'android'), platform, 'web') = 'ios'",
                 Harness.platform_where('ios')
  end

  test 'platform_where: valid platform with table prefix' do
    assert_equal "AND if(vd.platform IN ('ios', 'android'), vd.platform, 'web') = 'ios'",
                 Harness.platform_where('ios', table: 'vd')
  end

  test 'platform_where: a desktop-family value matches the web bucket, not nothing' do
    %w[web mac windows desktop].each do |raw|
      assert_equal "AND if(platform IN ('ios', 'android'), platform, 'web') = 'web'",
                   Harness.platform_where(raw), "#{raw} must resolve to the web bucket"
    end
  end

  test 'platform_where: an unknown platform is escaped and matches nothing' do
    result = Harness.platform_where("ios'; DROP TABLE events; --")

    assert_includes result, "\\'", 'the quote must be escaped'
    assert_not_includes result, "= 'web'", 'garbage must not silently resolve to a real bucket'
  end

  test 'platform_where: a typo matches nothing rather than the web bucket' do
    assert_equal "AND if(platform IN ('ios', 'android'), platform, 'web') = 'iOS'",
                 Harness.platform_where('iOS')
  end

  # ── log_query_failure ───────────────────────────────────────────────
  # The method uses bare `raise` which re-raises $! when inside a rescue block.
  test 'log_query_failure: re-raises ArgumentError' do
    raised = assert_raises(ArgumentError) do
      Harness.log_query_failure(:test_method, ArgumentError.new('bad arg'))
    end
    assert_equal 'bad arg', raised.message
  end

  test 'log_query_failure: re-raises Date::Error' do
    raised = assert_raises(Date::Error) do
      Harness.log_query_failure(:test_method, Date::Error.new('bad date'))
    end
    assert_equal 'bad date', raised.message
  end

  test 'log_query_failure: logs and does not raise for RuntimeError' do
    error = RuntimeError.new('CH connection failed')
    assert_nothing_raised do
      Harness.log_query_failure(:test_method, error)
    end
  end

  test 'log_query_failure: logs and does not raise for StandardError' do
    error = StandardError.new('timeout')
    assert_nothing_raised do
      Harness.log_query_failure(:test_method, error)
    end
  end

  test 'log_query_failure: logs and does not raise for IOError' do
    error = IOError.new('broken pipe')
    assert_nothing_raised do
      Harness.log_query_failure(:test_method, error)
    end
  end

  test 'log_query_failure: does not raise for non-propagated errors' do
    [RuntimeError.new('test'), StandardError.new('test'), IOError.new('test'),
     Errno::ECONNREFUSED.new].each do |error|
      assert_nothing_raised do
        Harness.log_query_failure(:test_method, error)
      end
    end
  end

  # ── parse_filters ────────────────────────────────────────────────────

  test 'parse_filters: Array passthrough' do
    input = [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }]
    assert_equal input, Harness.parse_filters(input)
  end

  test 'parse_filters: JSON string parsed' do
    json = '[{"field":"platform","operator":"is","value":"ios"}]'
    result = Harness.parse_filters(json)
    assert_equal 'platform', result.first['field']
  end

  test 'parse_filters: shorthand keys normalize to full filter shape' do
    result = Harness.parse_filters([{ 'f' => 'platform', 'o' => 'is', 'v' => 'ios' }])

    assert_equal [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }], result
  end

  test 'parse_filters: invalid JSON returns empty array' do
    assert_equal [], Harness.parse_filters('not json at all')
  end

  test 'parse_filters: nil returns empty array' do
    assert_equal [], Harness.parse_filters(nil)
  end

  test 'parse_filters: integer returns empty array' do
    assert_equal [], Harness.parse_filters(42)
  end

  # ── build_filter_clauses ─────────────────────────────────────────────

  test 'build_filter_clauses: is operator with scalar value' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => 'US' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal ["country = 'US'"], clauses
  end

  test 'build_filter_clauses: is operator with array value' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => %w[US DE] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal ["country IN ('US', 'DE')"], clauses
  end

  test 'build_filter_clauses: is_not operator with scalar' do
    filters = [{ 'field' => 'country', 'operator' => 'is_not', 'value' => 'US' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal ["country != 'US'"], clauses
  end

  test 'build_filter_clauses: is_not operator with array value' do
    filters = [{ 'field' => 'country', 'operator' => 'is_not', 'value' => %w[US DE] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal ["country NOT IN ('US', 'DE')"], clauses
  end

  test 'build_filter_clauses: contains operator' do
    filters = [{ 'field' => 'screen_name', 'operator' => 'contains', 'value' => 'Home' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[screen_name])
    assert_equal ["lower(screen_name) LIKE '%home%'"], clauses
  end

  test 'build_filter_clauses: unknown field rejected' do
    filters = [{ 'field' => 'secret', 'operator' => 'is', 'value' => 'x' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform])
    assert_equal [], clauses
  end

  test 'build_filter_clauses: blank field or operator skipped' do
    filters = [
      { 'field' => '', 'operator' => 'is', 'value' => 'x' },
      { 'field' => 'platform', 'operator' => '', 'value' => 'x' }
    ]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform])
    assert_equal [], clauses
  end

  test 'build_filter_clauses: SQL injection in value sanitized' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => "US'; DROP TABLE--" }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal 1, clauses.size
    assert_equal "country = 'US\\'; DROP TABLE--'", clauses.first
  end

  test 'build_filter_clauses: backslash-quote injection in value sanitized' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => "US\\'; DROP TABLE--" }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country])
    assert_equal 1, clauses.size
    # Backslash is doubled AND quote is escaped — injection fully neutralised
    assert_equal "country = 'US\\\\\\'; DROP TABLE--'", clauses.first
  end

  test 'build_filter_clauses: table prefix applied' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => 'US' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[country], table: 'se')
    assert_equal ["se.country = 'US'"], clauses
  end

  test 'build_filter_clauses: platform compares normalized column and value' do
    filters = [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'mac' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform])
    assert_equal ["if(platform IN ('ios', 'android'), platform, 'web') = 'web'"], clauses
  end

  test 'build_filter_clauses: platform array values normalized and deduped' do
    filters = [{ 'field' => 'platform', 'operator' => 'is', 'value' => %w[mac windows ios] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform])
    assert_equal ["if(platform IN ('ios', 'android'), platform, 'web') IN ('web', 'ios')"], clauses
  end

  test 'build_filter_clauses: platform table prefix applied inside normalization' do
    filters = [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform], table: 'se')
    assert_equal ["if(se.platform IN ('ios', 'android'), se.platform, 'web') = 'ios'"], clauses
  end

  test 'build_filter_clauses: nil filters returns empty' do
    assert_equal [], Harness.build_filter_clauses(nil, allowed_fields: %w[platform])
  end

  test 'build_filter_clauses: unknown operator ignored' do
    filters = [{ 'field' => 'platform', 'operator' => 'greater_than', 'value' => '5' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[platform])
    assert_equal [], clauses
  end

  # ── build_filter_clauses: integer fields ─────────────────────────────

  test 'build_filter_clauses: integer is with scalar' do
    filters = [{ 'field' => 'link_id', 'operator' => 'is', 'value' => '42' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id])
    assert_equal ['link_id = 42'], clauses
  end

  test 'build_filter_clauses: integer is with array' do
    filters = [{ 'field' => 'link_id', 'operator' => 'is', 'value' => %w[1 2 3] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id])
    assert_equal ['link_id IN (1, 2, 3)'], clauses
  end

  test 'build_filter_clauses: integer is_not with scalar' do
    filters = [{ 'field' => 'campaign_id', 'operator' => 'is_not', 'value' => '99' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[campaign_id])
    assert_equal ['campaign_id != 99'], clauses
  end

  test 'build_filter_clauses: integer is_not with array' do
    filters = [{ 'field' => 'campaign_id', 'operator' => 'is_not', 'value' => %w[5 10] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[campaign_id])
    assert_equal ['campaign_id NOT IN (5, 10)'], clauses
  end

  test 'build_filter_clauses: integer with non-numeric value skipped' do
    filters = [{ 'field' => 'link_id', 'operator' => 'is', 'value' => 'abc' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id])
    assert_equal [], clauses
  end

  test 'build_filter_clauses: integer with non-numeric array value skipped' do
    filters = [{ 'field' => 'link_id', 'operator' => 'is', 'value' => %w[1 abc] }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id])
    assert_equal [], clauses
  end

  test 'build_filter_clauses: integer with table prefix' do
    filters = [{ 'field' => 'link_id', 'operator' => 'is', 'value' => '7' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id], table: 'ss')
    assert_equal ['ss.link_id = 7'], clauses
  end

  test 'build_filter_clauses: integer unknown operator ignored' do
    filters = [{ 'field' => 'link_id', 'operator' => 'contains', 'value' => '5' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[link_id])
    assert_equal [], clauses
  end

  # ── build_filter_clauses: boolean fields ─────────────────────────────

  test 'build_filter_clauses: boolean true values' do
    %w[true 1].each do |val|
      filters = [{ 'field' => 'has_conversion', 'operator' => 'is', 'value' => val }]
      clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[has_conversion])
      assert_equal ['has_conversion = 1'], clauses, "Expected true for value=#{val}"
    end
  end

  test 'build_filter_clauses: boolean false values' do
    %w[false 0 anything].each do |val|
      filters = [{ 'field' => 'has_conversion', 'operator' => 'is', 'value' => val }]
      clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[has_conversion])
      assert_equal ['has_conversion = 0'], clauses, "Expected false for value=#{val}"
    end
  end

  test 'build_filter_clauses: boolean with table prefix' do
    filters = [{ 'field' => 'has_conversion', 'operator' => 'is', 'value' => 'true' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[has_conversion], table: 'ss')
    assert_equal ['ss.has_conversion = 1'], clauses
  end

  test 'build_filter_clauses: boolean is_not flips value' do
    filters = [{ 'field' => 'has_conversion', 'operator' => 'is_not', 'value' => 'true' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[has_conversion])
    assert_equal ['has_conversion = 0'], clauses, 'is_not true should produce = 0'
  end

  test 'build_filter_clauses: boolean is_not false produces = 1' do
    filters = [{ 'field' => 'has_conversion', 'operator' => 'is_not', 'value' => 'false' }]
    clauses = Harness.build_filter_clauses(filters, allowed_fields: %w[has_conversion])
    assert_equal ['has_conversion = 1'], clauses, 'is_not false should produce = 1'
  end

  # ── format_number ──────────────────────────────────────────────────

  test 'format_number: nil returns 0' do
    assert_equal '0', Harness.format_number(nil)
  end

  test 'format_number: zero returns 0' do
    assert_equal '0', Harness.format_number(0)
  end

  test 'format_number: small number unchanged' do
    assert_equal '500', Harness.format_number(500)
  end

  test 'format_number: thousands formatted with K' do
    assert_equal '1.5K', Harness.format_number(1500)
  end

  test 'format_number: millions formatted with M' do
    assert_equal '1.2M', Harness.format_number(1_200_000)
  end

  test 'format_number: billions formatted with B' do
    assert_equal '2.5B', Harness.format_number(2_500_000_000)
  end

  # ── format_duration_ms ─────────────────────────────────────────────

  test 'format_duration_ms: nil returns nil' do
    assert_nil Harness.format_duration_ms(nil)
  end

  test 'format_duration_ms: zero returns nil' do
    assert_nil Harness.format_duration_ms(0)
  end

  test 'format_duration_ms: negative returns nil' do
    assert_nil Harness.format_duration_ms(-100)
  end

  test 'format_duration_ms: seconds only' do
    assert_equal '45s', Harness.format_duration_ms(45_000)
  end

  test 'format_duration_ms: minutes and seconds' do
    assert_equal '2m 30s', Harness.format_duration_ms(150_000)
  end

  test 'format_duration_ms: hours and minutes' do
    assert_equal '1h 1m', Harness.format_duration_ms(3_661_000)
  end

  # ── display_source_name ────────────────────────────────────────────

  test 'display_source_name: organic returns Organic' do
    assert_equal 'Organic', Harness.display_source_name('organic')
  end

  test 'display_source_name: campaigns returns Campaigns' do
    assert_equal 'Campaigns', Harness.display_source_name('campaigns')
  end

  test 'display_source_name: referrals returns Referrals' do
    assert_equal 'Referrals', Harness.display_source_name('referrals')
  end

  test 'display_source_name: api_links returns API Links' do
    assert_equal 'API Links', Harness.display_source_name('api_links')
  end

  test 'display_source_name: links returns Links' do
    assert_equal 'Links', Harness.display_source_name('links')
  end

  test 'display_source_name: unknown source gets titleized' do
    assert_equal 'Unknown Thing', Harness.display_source_name('unknown_thing')
  end

  # ── source SQL helpers ──────────────────────────────────────────────

  test 'source_type_expr: emits source classifier without table alias' do
    expr = Harness.source_type_expr

    assert_includes expr, "campaign_id > 0, 'campaigns'"
    assert_includes expr, "sdk_generated = 1 AND link_visitor_id > 0, 'referrals'"
    assert_includes expr, "link_id > 0, 'links'"
    assert_includes expr, "'organic'"
  end

  test 'source_type_expr: prefixes columns when table alias is provided' do
    expr = Harness.source_type_expr('ss')

    assert_includes expr, "ss.campaign_id > 0"
    assert_includes expr, "ss.sdk_generated = 1 AND ss.link_visitor_id = 0"
    assert_includes expr, "ss.link_id > 0"
  end

  # Each bucket's predicate is its own condition AND the negation of all
  # higher-priority conditions, so classify (source_type_expr) == filter.
  test 'source_where_clause: returns exact filters for every source category' do
    not_campaign = 'NOT (ss.campaign_id > 0)'
    not_referral = 'NOT (ss.sdk_generated = 1 AND ss.link_visitor_id > 0)'
    not_api      = 'NOT (ss.sdk_generated = 1 AND ss.link_visitor_id = 0)'
    not_link     = 'NOT (ss.link_id > 0)'
    expected = {
      'campaigns' => 'ss.campaign_id > 0',
      'referrals' => "#{not_campaign} AND ss.sdk_generated = 1 AND ss.link_visitor_id > 0",
      'api_links' => "#{not_campaign} AND #{not_referral} AND ss.sdk_generated = 1 AND ss.link_visitor_id = 0",
      'links' => "#{not_campaign} AND #{not_referral} AND #{not_api} AND ss.link_id > 0",
      'organic' => "#{not_campaign} AND #{not_referral} AND #{not_api} AND #{not_link}"
    }

    expected.each do |source, clause|
      assert_equal clause, Harness.source_where_clause(source, 'ss'), "source=#{source}"
    end
  end

  test 'source_where_clause: unknown source returns nil' do
    assert_nil Harness.source_where_clause('unknown')
  end

  # ── ID field resolver guards ────────────────────────────────────────

  test 'resolve_id_field: rejects unknown ClickHouse table names before querying' do
    error = assert_raises(ArgumentError) do
      Harness.resolve_id_field(1, 'link_id', ch_table: 'events; DROP TABLE events')
    end

    assert_match(/Invalid CH table/, error.message)
  end

  test 'resolve_visitor_field: rejects unknown ClickHouse table names before querying' do
    error = assert_raises(ArgumentError) do
      Harness.resolve_visitor_field(1, ch_table: 'visitors')
    end

    assert_match(/Invalid CH table/, error.message)
  end

  test 'resolve_id_field: rejects a column not on the allowlist before querying' do
    error = assert_raises(ArgumentError) do
      Harness.resolve_id_field(1, 'visitor_id) FROM events; DROP TABLE events--', ch_table: 'events')
    end

    assert_match(/Invalid CH column/, error.message)
  end

  test 'ch_id_set: rejects a column not on the allowlist before querying' do
    error = assert_raises(ArgumentError) do
      Harness.ch_id_set(1, 'device_id', '', ch_table: 'events')
    end

    assert_match(/Invalid CH column/, error.message)
  end

  test 'resolve_visitor_field: rejects a non-integer project id before querying' do
    assert_raises(ArgumentError) { Harness.resolve_visitor_field('1 OR 1=1', ch_table: 'events') }
  end

  test 'ch_id_set: rejects unknown ClickHouse table names before querying' do
    error = assert_raises(ArgumentError) do
      Harness.ch_id_set(1, 'link_id', '', ch_table: 'links')
    end

    assert_match(/Invalid CH table/, error.message)
  end

  test 'resolve_visitor_field: non-numeric query returns empty values without querying' do
    assert_equal(
      { values: [], next_cursor: nil },
      Harness.resolve_visitor_field(1, q: 'not-a-visitor-id')
    )
  end

  # ── safe_percent ───────────────────────────────────────────────────

  test 'safe_percent: normal division' do
    assert_equal 33.3, Harness.safe_percent(1, 3)
  end

  test 'safe_percent: zero numerator' do
    assert_equal 0.0, Harness.safe_percent(0, 5)
  end

  test 'safe_percent: zero denominator returns 0.0' do
    assert_equal 0.0, Harness.safe_percent(5, 0)
  end

  test 'safe_percent: nil denominator returns 0.0' do
    assert_equal 0.0, Harness.safe_percent(5, nil)
  end

  # ── format_number boundary values (T4) ─────────────────────────────

  test 'format_number: 999 stays as plain number' do
    assert_equal '999', Harness.format_number(999)
  end

  test 'format_number: 1000 becomes 1.0K' do
    assert_equal '1.0K', Harness.format_number(1_000)
  end

  test 'format_number: 999999 becomes 1.0M not 1000.0K' do
    assert_equal '1.0M', Harness.format_number(999_999)
  end

  test 'format_number: 999999999 becomes 1.0B not 1000.0M' do
    assert_equal '1.0B', Harness.format_number(999_999_999)
  end

  test 'format_number: negative number returns string' do
    assert_equal '-5', Harness.format_number(-5)
  end

  # ── Input rejection (injection resistance) ───────────────────────────

  test 'Integer() rejects non-numeric project_id' do
    assert_raises(ArgumentError) { Integer("1; DROP TABLE--") }
    assert_raises(ArgumentError) { Integer("abc") }
    assert_raises(TypeError) { Integer(nil) }
  end

  test 'sanitize_date neutralizes SQL injection payloads' do
    # Date.parse is lenient — extracts the date portion, discards the payload.
    # Defense is normalization: the output is always a clean YYYY-MM-DD string.
    assert_equal '2026-01-01', Harness.sanitize_date("2026-01-01'; DROP TABLE--")
    assert_equal '2026-01-01', Harness.sanitize_date("2026-01-01' UNION SELECT 1--")
    # Payloads without a valid date prefix are rejected
    assert_raises(Date::Error) { Harness.sanitize_date("' OR 1=1--") }
    assert_raises(Date::Error) { Harness.sanitize_date("DROP TABLE events") }
  end

  # ── with_guard ───────────────────────────────────────────────────────

  test 'with_guard appends SETTINGS and strips trailing semicolon' do
    captured = nil
    fake_conn = Object.new
    fake_conn.define_singleton_method(:select_all) do |sql| 
      captured = sql
      []
    end
    Clickhouse.stub(:with, ->(&blk) { blk.call(fake_conn) }) do
      Analytics::EventsQueryService.send(:with_guard, 'SELECT 1;')
    end
    assert_match(/SELECT 1\n/, captured)
    assert_match(/SETTINGS max_execution_time = 25/, captured)
    assert_match(/max_memory_usage = 4000000000/, captured)
    assert_no_match(/;/, captured)
  end

  test 'with_guard maps a Net::ReadTimeout to QueryTooHeavy' do
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise Net::ReadTimeout }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      assert_raises(Analytics::QueryTooHeavy) { Analytics::EventsQueryService.send(:with_guard, 'SELECT 1') }
    end
  end

  test 'with_guard preserves the original message when mapping a read timeout' do
    original = Net::ReadTimeout.new('SELECT 1')
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise original }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      raised = assert_raises(Analytics::QueryTooHeavy) { Analytics::EventsQueryService.send(:with_guard, 'SELECT 1') }
      assert_equal original.message, raised.message
    end
  end

  test 'with_guard propagates a Net::OpenTimeout instead of mapping it to QueryTooHeavy' do
    # A connection-establishment timeout (CH unreachable / saturated) is an
    # AVAILABILITY failure, not a heavy query — it must propagate, not become a 422.
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise Net::OpenTimeout, 'execution expired' }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      assert_raises(Net::OpenTimeout) { Analytics::EventsQueryService.send(:with_guard, 'SELECT 1') }
    end
  end

  test 'with_guard maps timeout DatabaseError to QueryTooHeavy' do
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise ClickHouse::Client::DatabaseError, 'Code: 159. DB::Exception: Timeout exceeded: elapsed 1005.608 ms, maximum: 1000 ms. (TIMEOUT_EXCEEDED) (version 26.3.9.8 (official build))' }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      assert_raises(Analytics::QueryTooHeavy) { Analytics::EventsQueryService.send(:with_guard, 'SELECT 1') }
    end
  end

  test 'with_guard maps memory DatabaseError to QueryTooHeavy' do
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise ClickHouse::Client::DatabaseError, 'Code: 241. DB::Exception: Query memory limit exceeded: would use 5.50 MiB (attempt to allocate chunk of 5.50 MiB), maximum: 976.56 KiB. (MEMORY_LIMIT_EXCEEDED) (version 26.3.9.8 (official build))' }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      assert_raises(Analytics::QueryTooHeavy) { Analytics::EventsQueryService.send(:with_guard, 'SELECT 1') }
    end
  end

  test 'with_guard re-raises a non-heavy DatabaseError unchanged (genuine bug not masked)' do
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise ClickHouse::Client::DatabaseError, 'Code: 47. Unknown identifier foo' }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      assert_raises(ClickHouse::Client::DatabaseError) { Analytics::EventsQueryService.send(:with_guard, 'SELECT foo') }
    end
  end
end
