# lib/tasks/cache_metrics.rake
#
# Reports ModelCachingExtension cache hit/miss rates from Redis counters.
#
# Usage:
#   bundle exec rake cache_metrics:report            # today
#   DATE=2026-03-18 bundle exec rake cache_metrics:report  # specific date
#   DAYS=7 bundle exec rake cache_metrics:report     # last 7 days combined
#
namespace :cache_metrics do
  desc "Report ModelCachingExtension cache hit/miss rates"
  task report: :environment do
    days = (ENV["DAYS"] || 1).to_i
    dates = if ENV["DATE"]
              [ENV["DATE"]]
            else
              (0...days).map { |i| (Date.current - i).to_s }
            end

    totals = Hash.new { |h, k| h[k] = { hits: 0, misses: 0 } }

    dates.each do |date|
      data = REDIS.hgetall("cache_metrics:#{date}")
      data.each do |field, value|
        model, type = field.rpartition(":")
        next unless %w[hits misses].include?(type)
        totals[model][type.to_sym] += value.to_i
      end
    end

    if totals.empty?
      puts "No cache metrics found for #{dates.size > 1 ? "#{dates.last} .. #{dates.first}" : dates.first}"
      next
    end

    header = dates.size > 1 ? "#{dates.last} .. #{dates.first} (#{dates.size} days)" : dates.first
    puts "Cache hit/miss report for #{header}"
    puts "-" * 62
    printf "%-28<model>s %10<hits>s %10<misses>s %10<rate>s\n",
           model: "Model", hits: "Hits", misses: "Misses", rate: "Hit Rate"
    puts "-" * 62

    grand_hits = 0
    grand_misses = 0

    totals.sort_by { |_, v| -(v[:hits] + v[:misses]) }.each do |model, counts|
      total = counts[:hits] + counts[:misses]
      rate = total > 0 ? (counts[:hits].to_f / total * 100) : 0
      printf "%-28<model>s %10<hits>s %10<misses>s %9.1<rate>f%%\n",
             model: model,
             hits: delimit(counts[:hits]),
             misses: delimit(counts[:misses]),
             rate: rate
      grand_hits += counts[:hits]
      grand_misses += counts[:misses]
    end

    puts "-" * 62
    grand_total = grand_hits + grand_misses
    grand_rate = grand_total > 0 ? (grand_hits.to_f / grand_total * 100) : 0
    printf "%-28<model>s %10<hits>s %10<misses>s %9.1<rate>f%%\n",
           model: "TOTAL", hits: delimit(grand_hits), misses: delimit(grand_misses), rate: grand_rate
  end
end

def delimit(number)
  number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end
