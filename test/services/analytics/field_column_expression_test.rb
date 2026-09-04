# frozen_string_literal: true

require 'test_helper'

# Pure-Ruby (no ClickHouse) unit tests for the field -> SQL column expression
# mapping and the widened property-key validator. These run in the default
# suite. The picker-vs-filter invariant lives here: every key the picker can
# surface (non-identifier keys included) must produce a real filter clause, and
# only genuinely unsafe keys (backtick/space/control/oversize) return nil.
class Analytics::FieldColumnExpressionTest < ActiveSupport::TestCase
  Service = Analytics::EventsQueryService

  def expr(field)
    Service.send(:field_column_expression, field)
  end

  test 'returns CAST subcolumn for a plain key' do
    assert_equal 'CAST(properties.`plan` AS String)', expr('plan')
  end

  test 'returns the column name for an allowed attribute' do
    assert_equal 'event_type', expr('event_type')
  end

  test 'allows non-identifier JSON keys (picker == filterable)' do
    %w[user-id 2fa $set a.b.c].each do |k|
      assert_equal "CAST(properties.`#{k}` AS String)", expr(k),
                   "expected #{k} to be filterable, not skipped"
    end
  end

  test 'rejects backtick / control / space / oversize / empty keys (nil so caller skips)' do
    rejected = [
      'has`tick',        # backtick breaks the `properties.`key`` quoting
      "new\nline",       # newline (control char)
      'with space',      # space
      "tab\tk",          # tab (control char)
      ' null',           # leading space
      'x' * 257,         # > 256 bytes
      ''                 # empty
    ]
    rejected.each do |k|
      assert_nil expr(k), "expected #{k.inspect} to be rejected (nil)"
    end
  end

  # SECURITY REGRESSION: backslash escapes the template's closing backtick inside
  # the `properties.`key`` quoting, breaking out into raw SQL (verified cross-tenant
  # injection vector). The allowlist is the SOLE injection defense here, so it MUST
  # reject backslash (and DEL for hygiene). See events_filter_coverage_test.rb for
  # the real-ClickHouse scope-escape proof.
  test 'rejects backslash and DEL keys (cross-tenant injection vector)' do
    rejected = [
      'x\\',     # trailing backslash -- escapes the closing backtick
      'a\\b',    # embedded backslash
      'a\\\\',   # double backslash
      "a\x7fb"   # DEL (0x7f)
    ]
    rejected.each do |k|
      assert_nil expr(k), "expected #{k.inspect} to be rejected (nil)"
      assert_not Service.valid_property_key?(k),
                 "valid_property_key? must reject #{k.inspect}"
    end
  end

  # valid_property_key? is public on purpose (fields/picker calls it). Lock that.
  test 'valid_property_key? is a public class method matching field_column_expression' do
    assert_respond_to Service, :valid_property_key?
    assert Service.valid_property_key?('user-id')
    assert Service.valid_property_key?('a.b.c')
    assert_not Service.valid_property_key?('with space')
    assert_not Service.valid_property_key?('has`tick')
    assert_not Service.valid_property_key?('')
    assert_not Service.valid_property_key?('x' * 257)
    assert Service.valid_property_key?('x' * 256)
    assert_not Service.valid_property_key?(nil)
    assert_not Service.valid_property_key?(:symbol)
  end
end
