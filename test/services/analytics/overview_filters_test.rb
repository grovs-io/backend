# frozen_string_literal: true

require 'test_helper'

class Analytics::OverviewFiltersTest < ActiveSupport::TestCase
  test 'no filters → rollup mode without platform' do
    r = Analytics::OverviewFilters.resolve(nil)
    assert_equal :rollup, r.mode
    assert_nil r.platform
    assert_empty r.clauses
    assert_equal '', r.digest
  end

  test 'top-level platform param → rollup mode with that platform' do
    r = Analytics::OverviewFilters.resolve(nil, platform: 'ios')
    assert_equal :rollup, r.mode
    assert_equal 'ios', r.platform
  end

  test 'single platform-is chip → rollup mode' do
    r = Analytics::OverviewFilters.resolve('[{"field":"platform","operator":"is","value":"android"}]')
    assert_equal :rollup, r.mode
    assert_equal 'android', r.platform
  end

  test 'a chip with a blank operator is ignored and stays on the rollup path' do
    r = Analytics::OverviewFilters.resolve('[{"field":"country","operator":"","value":"RO"}]')
    assert_equal :rollup, r.mode
  end

  test 'non-platform chip → raw mode with a WHERE clause and a digest' do
    r = Analytics::OverviewFilters.resolve(
      '[{"field":"country","operator":"is","value":"RO"},{"field":"platform","operator":"is","value":"ios"}]'
    )
    assert r.raw?
    assert_equal 'ios', r.platform
    assert_includes r.clauses, "country = 'RO'"
    assert_equal 12, r.digest.length
  end

  test 'platform is_not → raw mode, no simple platform' do
    r = Analytics::OverviewFilters.resolve('[{"field":"platform","operator":"is_not","value":"ios"}]')
    assert r.raw?
    assert_nil r.platform
    assert_equal 1, r.clauses.size
  end

  test 'property filter clause uses the JSON subcolumn cast' do
    r = Analytics::OverviewFilters.resolve('[{"field":"plan","operator":"is","value":"pro"}]')
    assert r.raw?
    assert_equal ["CAST(properties.`plan` AS String) = 'pro'"], r.clauses
  end

  test 'same filters give the same digest, different filters a different one' do
    a = Analytics::OverviewFilters.resolve('[{"field":"country","operator":"is","value":"RO"}]')
    b = Analytics::OverviewFilters.resolve('[{"field":"country","operator":"is","value":"RO"}]')
    c = Analytics::OverviewFilters.resolve('[{"field":"country","operator":"is","value":"DE"}]')
    assert_equal a.digest, b.digest
    assert_not_equal a.digest, c.digest
  end

  test 'source chips resolve to taxonomy predicates' do
    r = Analytics::OverviewFilters.resolve('[{"field":"source","operator":"is","value":"organic"}]')
    assert r.raw?
    assert_equal ["(#{Analytics::SourceTaxonomy.where_clause('organic')})"], r.clauses
  end

  test 'source is_not negates, arrays OR, unknown buckets are dropped' do
    r = Analytics::OverviewFilters.resolve('[{"field":"source","operator":"is_not","value":"campaigns"}]')
    assert_equal ["NOT (#{Analytics::SourceTaxonomy.where_clause('campaigns')})"], r.clauses
    r = Analytics::OverviewFilters.resolve('[{"field":"source","operator":"is","value":["links","referrals"]}]')
    assert_equal ["(#{Analytics::SourceTaxonomy.where_clause('links')} OR #{Analytics::SourceTaxonomy.where_clause('referrals')})"], r.clauses
    # An unknown bucket produces no clause, so it raises rather than silently serving rollup.
    assert_raises(Analytics::OverviewFilters::Unsupported) do
      Analytics::OverviewFilters.resolve('[{"field":"source","operator":"is","value":"bogus"}]')
    end
  end

  test 'language is a filterable attribute' do
    r = Analytics::OverviewFilters.resolve('[{"field":"language","operator":"is","value":"ro"}]')
    assert_equal ["language = 'ro'"], r.clauses
  end

  test 'duplicate identical platform chips collapse to a single rollup filter' do
    dup = Analytics::OverviewFilters.resolve(
      '[{"field":"platform","operator":"is","value":"ios"},{"field":"platform","operator":"is","value":"ios"}]'
    )
    single = Analytics::OverviewFilters.resolve('[{"field":"platform","operator":"is","value":"ios"}]')
    assert_equal :rollup, dup.mode
    assert_equal 'ios', dup.platform
    assert_equal single.digest, dup.digest
  end

  test 'a chip that produces no SQL raises Unsupported instead of an unfiltered rollup answer' do
    chips = JSON.generate([{ field: 'link_id', operator: 'contains', value: 'x' }])
    err = assert_raises(Analytics::OverviewFilters::Unsupported) { Analytics::OverviewFilters.resolve(chips) }
    assert_equal 'Unsupported filter: link_id contains', err.message
  end

  # link_id contains is genuinely empty; has_conversion contains resolves as a property LIKE.
  test 'a supported chip mixed with an unsupported one still raises' do
    chips = JSON.generate([{ field: 'country', operator: 'is', value: 'RO' },
                           { field: 'link_id', operator: 'contains', value: 'x' }])
    assert_raises(Analytics::OverviewFilters::Unsupported) { Analytics::OverviewFilters.resolve(chips) }
  end
end
