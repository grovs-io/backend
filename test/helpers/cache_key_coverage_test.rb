require "test_helper"

# Ensures every `redis_find_by` / `redis_find_by_multiple_conditions` call site
# is covered by the corresponding model's `cache_keys_to_clear` implementation.
#
# Two complementary checks:
#   1. Static scan — regex-matches all call sites and compares against a
#      checked-in manifest. Fails when someone adds a new lookup without
#      updating this file (forces awareness).
#   2. Runtime coverage — loads fixture records and asserts the generated
#      cache keys actually match the lookup patterns.
class CacheKeyCoverageTest < ActiveSupport::TestCase
  fixtures :devices, :visitors, :projects, :instances, :domains,
           :links, :applications, :installed_apps

  # ── Manifest of every redis_find_by / redis_find_by_multiple_conditions
  #    call site in the codebase. When you add a new lookup, add an entry
  #    here AND update the model's cache_keys_to_clear.
  #
  #    Format:
  #      { model:, type: :simple|:multi, key:/conditions:, includes: }
  #
  EXPECTED_LOOKUPS = [
    # Device
    { model: "Device", type: :simple, key: :vendor,     includes: nil },
    { model: "Device", type: :simple, key: :id,         includes: nil },

    # Project
    { model: "Project", type: :simple, key: :id,         includes: nil },
    { model: "Project", type: :simple, key: :identifier, includes: :instance },

    # Instance
    { model: "Instance", type: :simple, key: :id,         includes: nil },
    { model: "Instance", type: :simple, key: :uri_scheme, includes: nil },

    # Visitor
    { model: "Visitor", type: :simple, key: :id, includes: [:device] },
    { model: "Visitor", type: :multi,  conditions: { id: :id, project_id: :project_id },
                                       includes: [:device] },
    { model: "Visitor", type: :multi,  conditions: { device_id: :device_id, project_id: :project_id },
                                       includes: [:device] },
    { model: "Visitor", type: :multi,  conditions: { device_id: :device_id, project_id: :project_id },
                                       includes: nil },

    # Domain
    { model: "Domain", type: :multi, conditions: { domain: :domain, subdomain: :subdomain },
                                     includes: nil },

    # Link
    { model: "Link", type: :multi, conditions: { path: :path, domain_id: :domain_id },
                                   includes: nil },
    { model: "Link", type: :multi, conditions: { domain: :domain_id, path: :path },
                                   includes: nil },

    # Application
    { model: "Application", type: :multi, conditions: { instance_id: :instance_id, platform: :platform },
                                          includes: nil },

    # InstalledApp
    { model: "InstalledApp", type: :multi, conditions: { device_id: :device_id, project_id: :project_id },
                                           includes: nil },
  ].freeze

  # ── Test A: Static scan ──────────────────────────────────────────────
  #
  # Regex-scan app/ for all redis_find_by* calls. Each call site must map
  # to an entry in EXPECTED_LOOKUPS. If this test fails, a new lookup was
  # added without updating the manifest above.
  test "all redis_find_by call sites are in EXPECTED_LOOKUPS manifest" do
    app_dir = Rails.root.join("app")
    call_pattern = /(\w+)\.redis_find_by(?:_multiple_conditions)?\s*\(/
    simple_pattern = /\.redis_find_by\(\s*:(\w+)\s*,/
    multi_pattern = /\.redis_find_by_multiple_conditions\(\s*\{([^}]+)\}/

    discovered = []

    Dir.glob(app_dir.join("**/*.rb")).each do |file|
      # Skip the definition file
      next if file.end_with?("model_caching_extension.rb")

      content = File.read(file)
      content.each_line.with_index(1) do |line, lineno|
        next if line.strip.start_with?("#")
        next unless line.match?(call_pattern)

        if (m = line.match(/(\w+)\.redis_find_by\(\s*:(\w+)\s*,/))
          model = m[1]
          key = m[2].to_sym
          includes_match = line.match(/includes:\s*(\[?:[\w,\s:\[\]]+\]?)/)
          includes = parse_includes(includes_match&.captures&.first)
          discovered << { model: model, type: :simple, key: key, includes: includes,
                          location: "#{file}:#{lineno}" }
        elsif (m = line.match(/(\w+)\.redis_find_by_multiple_conditions\(\s*\{([^}]+)\}/))
          model = m[1]
          cond_keys = m[2].scan(/(\w+):/).flatten.map(&:to_sym)
          includes_match = line.match(/includes:\s*(\[?:[\w,\s:\[\]]+\]?)/)
          includes = parse_includes(includes_match&.captures&.first)
          discovered << { model: model, type: :multi, condition_keys: cond_keys.sort,
                          includes: includes, location: "#{file}:#{lineno}" }
        # Handle implicit self calls (e.g., redis_find_by_multiple_conditions without Model.)
        elsif (m = line.match(/redis_find_by_multiple_conditions\(\s*\{([^}]+)\}/))
          # Determine model from file path
          model = infer_model_from_path(file)
          cond_keys = m[1].scan(/(\w+):/).flatten.map(&:to_sym)
          includes_match = line.match(/includes:\s*(\[?:[\w,\s:\[\]]+\]?)/)
          includes = parse_includes(includes_match&.captures&.first)
          discovered << { model: model, type: :multi, condition_keys: cond_keys.sort,
                          includes: includes, location: "#{file}:#{lineno}" }
        elsif (m = line.match(/redis_find_by\(\s*:(\w+)\s*,/))
          model = infer_model_from_path(file)
          key = m[1].to_sym
          includes_match = line.match(/includes:\s*(\[?:[\w,\s:\[\]]+\]?)/)
          includes = parse_includes(includes_match&.captures&.first)
          discovered << { model: model, type: :simple, key: key, includes: includes,
                          location: "#{file}:#{lineno}" }
        end
      end
    end

    # Normalize EXPECTED_LOOKUPS for comparison
    expected_signatures = EXPECTED_LOOKUPS.map { |e| normalize_entry(e) }.to_set

    missing = []
    discovered.each do |d|
      sig = normalize_discovered(d)
      unless expected_signatures.include?(sig)
        missing << "#{d[:location]}: #{sig.inspect}"
      end
    end

    assert missing.empty?,
           "Found redis_find_by call sites not in EXPECTED_LOOKUPS manifest. " \
           "Add entries for:\n  #{missing.join("\n  ")}"
  end

  # ── Test B: Runtime coverage ─────────────────────────────────────────
  #
  # For each EXPECTED_LOOKUPS entry, load a fixture, call cache_keys_to_clear,
  # and verify the expected key pattern appears.
  test "cache_keys_to_clear covers every expected lookup pattern" do
    EXPECTED_LOOKUPS.each do |entry|
      record = fixture_for(entry[:model])
      assert record, "No fixture found for #{entry[:model]}"

      # Device fixtures lack vendor — set it for the test
      record.vendor = "test-vendor" if entry[:model] == "Device" && record.vendor.blank?

      keys = record.cache_keys_to_clear

      expected_key = build_expected_key(record, entry)
      next unless expected_key # :id with no_includes is handled by super (default)

      assert keys.include?(expected_key),
             "#{entry[:model]}#cache_keys_to_clear missing key for " \
             "#{entry.inspect}\n  Expected: #{expected_key}\n  Got: #{keys.inspect}"
    end
  end

  private

  def parse_includes(str)
    return nil if str.nil?

    str = str.strip
    if str.start_with?("[")
      # e.g., "[:device]" or "[:device, :project]"
      str.scan(/:(\w+)/).flatten.map(&:to_sym)
    else
      # e.g., ":instance"
      str.delete(":").strip.to_sym
    end
  end

  def infer_model_from_path(file)
    basename = File.basename(file, ".rb")
    basename.camelize
  end

  def normalize_entry(entry)
    if entry[:type] == :simple
      { model: entry[:model], type: :simple, key: entry[:key],
        includes: normalize_includes(entry[:includes]) }
    else
      { model: entry[:model], type: :multi,
        condition_keys: entry[:conditions].keys.sort,
        includes: normalize_includes(entry[:includes]) }
    end
  end

  def normalize_discovered(entry)
    if entry[:type] == :simple
      { model: entry[:model], type: :simple, key: entry[:key],
        includes: normalize_includes(entry[:includes]) }
    else
      { model: entry[:model], type: :multi,
        condition_keys: entry[:condition_keys].sort,
        includes: normalize_includes(entry[:includes]) }
    end
  end

  def normalize_includes(inc)
    case inc
    when nil then nil
    when Array then inc.map(&:to_sym).sort
    when Symbol then [inc].sort
    else nil
    end
  end

  def fixture_for(model_name)
    case model_name
    when "Device"      then devices(:ios_device)
    when "Project"     then projects(:one)
    when "Instance"    then instances(:one)
    when "Visitor"     then visitors(:ios_visitor)
    when "Domain"      then domains(:one)
    when "Link"        then links(:basic_link)
    when "Application" then applications(:ios_app)
    when "InstalledApp" then installed_apps(:one)
    end
  end

  def build_expected_key(record, entry)
    prefix = record.class.cache_prefix

    if entry[:type] == :simple
      key_attr = entry[:key]
      value = record.send(key_attr)
      includes_part = format_includes_part(entry[:includes])

      # :id with no_includes is covered by the default super — skip
      return nil if key_attr == :id && includes_part == "no_includes"

      "#{prefix}:find_by:#{key_attr}:#{value}:#{includes_part}"
    else
      # Multi-condition: use the model's multi_condition_cache_key helper
      conditions = entry[:conditions].transform_values { |attr| record.send(attr) }
      record.send(:multi_condition_cache_key, conditions, includes: entry[:includes])
    end
  end

  def format_includes_part(includes)
    case includes
    when nil then "no_includes"
    when Array then "includes:#{includes.map(&:to_s).sort.join(',')}"
    when Symbol then "includes:#{includes}"
    else "no_includes"
    end
  end
end
