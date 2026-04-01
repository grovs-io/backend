require 'redis'

module ModelCachingExtension
  extend ActiveSupport::Concern

  module ClassMethods
    # Fetches all records with caching
    def all_cached
      cache_key = "#{cache_prefix}:all"
      cached_result = fetch_from_cache(cache_key)

      if cached_result.nil?
        result = all.to_a
        store_in_cache(cache_key, result)
        result
      else
        cached_result
      end
    end

    # Fetches a single record by a specified attribute with caching
    def redis_find_by_hashid(value)
      cache_key = "#{cache_prefix}:find_by_hash_id:#{value}"
      cached_result = fetch_from_cache(cache_key)

      if cached_result.nil?
        result = find_by_hashid(value)
        store_in_cache(cache_key, result) if result
        result
      else
        cached_result
      end
    end

    # IMPORTANT: When adding new lookup patterns, update the model's
    # cache_keys_to_clear method to include the new key for targeted invalidation.
    def redis_find_by(key, value, includes: nil)
      # Cache key needs to include information about the eager loaded associations
      includes_part = includes ? "includes:#{Array(includes).sort.join(',')}" : "no_includes"
      cache_key = "#{cache_prefix}:find_by:#{key}:#{value}:#{includes_part}"

      cached_result = fetch_from_cache(cache_key)

      if cached_result.nil?
        # Start with a base query
        query = self

        # Add eager loading if specified
        query = query.includes(includes) if includes

        # Execute the find_by with the key-value condition
        result = query.find_by(key => value)

        # Cache the result if found
        store_in_cache(cache_key, result) if result

        result
      else
        cached_result
      end
    end

    # IMPORTANT: When adding new lookup patterns, update the model's
    # cache_keys_to_clear method to include the new key for targeted invalidation.
    def redis_find_by_multiple_conditions(conditions, includes: nil, expires_in: 5.minutes, force: false)
      # Convert to hash if given array-style args (like [:id, 5])
      conditions = conditions.is_a?(Hash) ? conditions : { conditions[0] => conditions[1] }

      # Sort keys for consistent cache keys
      conditions = conditions.with_indifferent_access.sort.to_h

      # Generate cache key components
      includes_part = if includes
                        includes = Array(includes)
                        "includes:#{includes.map(&:to_s).sort.join(',')}"
                      else
                        "no_includes"
                      end

      conditions_part = conditions.map do |k, v|
        value = v.is_a?(Array) ? v.sort.join(',') : v
        "#{k}:#{value}"
      end.join('|')

      cache_key = "#{cache_prefix}:find_by:#{digest(conditions_part)}:#{digest(includes_part)}"

      # Return cached version unless forcing reload
      unless force
        cached_result = fetch_from_cache(cache_key)
        return cached_result unless cached_result.nil?
      end

      # Build and execute query
      query = all
      query = query.includes(includes) if includes
      result = query.find_by(conditions)

      # Cache result with expiration
      store_in_cache(cache_key, result, expires_in: expires_in) if result

      result
    end

    # Fetches multiple records by a key with an array of values
    def redis_fetch_by_values(key, values)
      # Create unique cache keys for each value
      cache_keys = values.map { |val| "#{cache_prefix}:find_by:#{key}:#{val}" }

      # Try to fetch all requested items from cache.
      # Per-item rescue: a single corrupted value must not break the entire batch.
      # Corrupt keys are evicted so the next request rebuilds from DB.
      cached_items = redis.mget(*cache_keys).each_with_index.map do |raw, i|
        next nil unless raw
        Marshal.load(raw)
      rescue StandardError => e
        Rails.logger.error("Redis cache corrupt value for #{cache_keys[i]}: #{e.message}")
        begin; redis.del(cache_keys[i]); rescue Redis::BaseError; nil; end
        nil
      end

      # Track cache hit/miss metrics
      hits = cached_items.count { |item| !item.nil? }
      misses = cached_items.size - hits
      track_cache_metric(:hit, hits) if hits > 0
      track_cache_metric(:miss, misses) if misses > 0

      # Find indexes of missing items
      missing_indexes = cached_items.each_with_index.select { |item, _| item.nil? }.map(&:last)

      # If we have missing items, fetch them from the database
      unless missing_indexes.empty?
        missing_values = missing_indexes.map { |i| values[i] }
        found_items = where(key => missing_values).to_a

        # Create a hash to look up found items by their key value
        found_by_value = found_items.index_by { |item| item.public_send(key) }

        # Update missing items in our result array and collect items to cache
        items_to_cache = []
        missing_indexes.each do |i|
          item = found_by_value[values[i]]
          if item
            cached_items[i] = item
            items_to_cache << ["#{cache_prefix}:find_by:#{key}:#{values[i]}", item]
          end
        end

        # Pipeline all cache writes into a single round-trip
        if items_to_cache.any?
          begin
            redis.with do |conn|
              conn.pipelined do |p|
                items_to_cache.each do |cache_key, item|
                  p.setex(cache_key, 5.minutes.to_i, Marshal.dump(item))
                end
              end
            end
          rescue Redis::BaseError, StandardError => e
            Rails.logger.error("Redis cache store error: #{e.message}")
          end
        end
      end

      # Return all items (both from cache and newly fetched)
      cached_items.compact
    end

    # Generate Redis cache prefix for this model
    def cache_prefix
      @cache_prefix ||= name.underscore.pluralize.to_s
    end

    private

    # Helper to fetch from cache with error handling
    def fetch_from_cache(key)
      data = redis.get(key)
      track_cache_metric(data ? :hit : :miss)
      data ? Marshal.load(data) : nil
    rescue Redis::BaseError, StandardError => e
      Rails.logger.error("Redis cache fetch error for #{key}: #{e.message}")
      # Corrupted value (Marshal.load failure) — evict so next request
      # rebuilds from DB instead of failing on every hit until TTL expires.
      (begin; redis.del(key); rescue Redis::BaseError; nil; end) if data
      nil
    end

    # Helper to store in cache with error handling.
    # 5-minute TTL: long enough to absorb read bursts (SDK auth checks hit
    # Project/Device lookups on every request) but short enough that stale
    # records self-heal quickly if an after_commit invalidation is missed
    # (e.g. during a Redis blip). Targeted DEL on after_commit handles the
    # normal case; TTL is the safety net.
    def store_in_cache(key, value, expires_in: 5.minutes)
      redis.setex(key, expires_in.to_i, Marshal.dump(value))
    rescue Redis::BaseError, StandardError => e
      Rails.logger.error("Redis cache store error for #{key}: #{e.message}")
      false
    end

    # Best-effort cache hit/miss tracking via Redis HINCRBY.
    # Daily-bucketed keys auto-expire after 7 days.
    def track_cache_metric(type, count = 1)
      date_key = "cache_metrics:#{Date.current}"
      field = "#{name}:#{type == :hit ? 'hits' : 'misses'}"
      redis.with do |conn|
        conn.pipelined do |p|
          p.hincrby(date_key, field, count)
          p.expire(date_key, 7.days.to_i)
        end
      end
    rescue Redis::BaseError, StandardError
      nil
    end

    # Access the Redis connection
    def redis
      ::REDIS
    end

    def digest(string)
      Digest::SHA1.hexdigest(string)[0..16]
    end
  end

  included do
    after_commit :clear_cache
  end

  # Instance methods defined on the module (not inside included do)
  # so that model overrides can call `super` properly.

  # Targeted cache clear for a specific record — avoids the full SCAN.
  # Pass the attribute names used in cached lookups (e.g., :id, :vendor).
  def clear_record_cache(*lookup_attributes)
    r = self.class.send(:redis)
    prefix = self.class.cache_prefix
    keys = lookup_attributes.filter_map do |attr|
      value = send(attr)
      "#{prefix}:find_by:#{attr}:#{value}:no_includes" if value.present?
    end
    r.del(*keys) unless keys.empty?
  rescue Redis::BaseError, StandardError => e
    Rails.logger.error("Redis targeted cache clear error: #{e.message}")
  end

  # Override in models to specify additional cache keys to clear on save.
  # Default clears :id and hashid lookup keys.
  def cache_keys_to_clear
    prefix = self.class.cache_prefix
    keys = ["#{prefix}:all"]
    keys << "#{prefix}:find_by:id:#{id}:no_includes" if id
    if respond_to?(:hashid) && id
      keys << "#{prefix}:find_by_hash_id:#{hashid}"
      # Also clear find_by(:id, hashid) — controllers pass hashids as id_param
      keys << "#{prefix}:find_by:id:#{hashid}:no_includes"
    end
    keys
  end

  protected

  # Helper to build a cache key matching redis_find_by_multiple_conditions format.
  def multi_condition_cache_key(conditions, includes: nil)
    prefix = self.class.cache_prefix
    sorted = conditions.with_indifferent_access.sort.to_h
    conditions_part = sorted.map { |k, v| "#{k}:#{v.is_a?(Array) ? v.sort.join(',') : v}" }.join('|')
    includes_part = includes ? "includes:#{Array(includes).map(&:to_s).sort.join(',')}" : "no_includes"
    d = ->(s) { Digest::SHA1.hexdigest(s)[0..16] }
    "#{prefix}:find_by:#{d.call(conditions_part)}:#{d.call(includes_part)}"
  end

  private

  def clear_cache
    r = self.class.send(:redis)
    keys = cache_keys_to_clear.uniq
    r.del(*keys) if keys.present?
  rescue Redis::BaseError, StandardError => e
    Rails.logger.error("Redis cache clear error: #{e.message}")
  end
end
