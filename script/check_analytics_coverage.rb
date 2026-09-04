#!/usr/bin/env ruby
# frozen_string_literal: true

# Asserts that every analytics file touched by the v1 simplification has >= 95%
# LINE coverage and that the analytics slice has >= 90% BRANCH coverage, reading
# SimpleCov's coverage/.resultset.json.
#
# Usage:
#   COVERAGE=1 bundle exec rails test test/services/analytics test/integration/analytics_*_test.rb
#   ruby script/check_analytics_coverage.rb
#
# Exits non-zero (and prints the offenders) if any matched file is below the bar.

require 'json'

LINE_THRESHOLD = 95.0
BRANCH_THRESHOLD = 90.0
PATTERNS = [
  %r{/app/services/analytics/},
  %r{/app/controllers/api/v1/analytics/}
].freeze

resultset_path = File.expand_path('../coverage/.resultset.json', __dir__)
unless File.exist?(resultset_path)
  warn "No coverage data at #{resultset_path}. Run the suite with COVERAGE=1 first."
  exit 1
end

# Merge line and branch hits across all recorded suites (a file may be exercised
# by several).
merged = Hash.new { |h, k| h[k] = [] }
merged_branches = Hash.new { |h, k| h[k] = {} }
JSON.parse(File.read(resultset_path)).each_value do |suite|
  (suite['coverage'] || {}).each do |file, data|
    lines = data.is_a?(Hash) ? data['lines'] : data
    if lines
      existing = merged[file]
      lines.each_with_index do |hit, i|
        next if hit.nil?

        existing[i] = [existing[i] || 0, hit].max
      end
    end

    branches = data.is_a?(Hash) ? data['branches'] : nil
    next unless branches

    branches.each do |type, entries|
      entries.each do |key, hit|
        branch_key = [type, key]
        merged_branches[file][branch_key] = [merged_branches[file][branch_key] || 0, hit.to_i].max
      end
    end
  end
end

rows = merged.filter_map do |file, lines|
  next unless PATTERNS.any? { |p| file.match?(p) }

  relevant = lines.count { |h| !h.nil? }
  next if relevant.zero?

  covered = lines.count { |h| !h.nil? && h.positive? }
  pct = (covered.to_f / relevant * 100).round(2)
  [file.sub(%r{.*/app/}, 'app/'), pct, covered, relevant]
end

if rows.empty?
  warn 'No analytics files found in coverage data — did the analytics tests run?'
  exit 1
end

rows.sort_by! { |_, pct, _, _| pct }
puts "Analytics line coverage (threshold #{LINE_THRESHOLD}%):"
rows.each do |file, pct, cov, rel|
  puts format('  %<pct>6.2f%%  %<file>-58s (%<cov>d/%<rel>d)', pct: pct, file: file, cov: cov, rel: rel)
end

offenders = rows.select { |_, pct, _, _| pct < LINE_THRESHOLD }
if offenders.any?
  warn "\nFAIL: #{offenders.size} analytics file(s) below #{LINE_THRESHOLD}% line coverage."
  exit 1
end

branch_total = 0
branch_covered = 0
merged_branches.each do |file, branches|
  next unless PATTERNS.any? { |p| file.match?(p) }

  branch_total += branches.size
  branch_covered += branches.values.count(&:positive?)
end

if branch_total.zero?
  warn 'No analytics branch coverage data found — is SimpleCov branch coverage enabled?'
  exit 1
end

branch_pct = (branch_covered.to_f / branch_total * 100).round(2)
puts format("\nAnalytics branch coverage (threshold %.1f%%): %6.2f%% (%d/%d)",
            BRANCH_THRESHOLD, branch_pct, branch_covered, branch_total)

if branch_pct < BRANCH_THRESHOLD
  warn "\nFAIL: analytics branch coverage below #{BRANCH_THRESHOLD}%."
  exit 1
end

puts "\nOK: all #{rows.size} analytics files >= #{LINE_THRESHOLD}% line coverage and analytics branch coverage >= #{BRANCH_THRESHOLD}%."
