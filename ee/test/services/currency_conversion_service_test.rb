require "test_helper"

class CurrencyConversionServiceTest < ActiveSupport::TestCase
  setup do
    @stub_rates = { "USD" => 1.0, "EUR" => 0.92, "GBP" => 0.79, "JPY" => 149.5 }
    Rails.cache.delete("exchange_rates")
    Rails.cache.delete("exchange_rates_last_known")
  end

  test "returns same amount for USD" do
    assert_equal 1000, CurrencyConversionService.to_usd_cents(1000, "USD")
  end

  test "converts known currency" do
    CurrencyConversionService.stub(:get_rates, @stub_rates) do
      result = CurrencyConversionService.to_usd_cents(920, "EUR")
      assert_equal (920.0 / 0.92).round, result
    end
  end

  test "returns nil for unsupported currency" do
    CurrencyConversionService.stub(:get_rates, @stub_rates) do
      result = CurrencyConversionService.to_usd_cents(1000, "XYZ")
      assert_nil result
    end
  end

  test "is case insensitive" do
    CurrencyConversionService.stub(:get_rates, @stub_rates) do
      result = CurrencyConversionService.to_usd_cents(1000, "usd")
      assert_equal 1000, result
    end
  end

  test "falls back to last-known rates on failure" do
    # Use memory store to test caching fallback behavior
    memory_store = ActiveSupport::Cache::MemoryStore.new
    memory_store.write("exchange_rates_last_known", @stub_rates)

    Rails.stub(:cache, memory_store) do
      CurrencyConversionService.stub(:fetch_from_primary, nil) do
        CurrencyConversionService.stub(:fetch_from_fallback, nil) do
          result = CurrencyConversionService.to_usd_cents(920, "EUR")
          assert_equal (920.0 / 0.92).round, result
        end
      end
    end
  end

  test "a failed fetch is not cached — next call retries and gets fresh rates" do
    memory_store = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, memory_store) do
      CurrencyConversionService.stub(:fetch_from_primary, nil) do
        CurrencyConversionService.stub(:fetch_from_fallback, nil) do
          assert_nil CurrencyConversionService.to_usd_cents(920, "EUR")
        end
      end

      CurrencyConversionService.stub(:fetch_from_primary, @stub_rates) do
        assert_equal (920.0 / 0.92).round, CurrencyConversionService.to_usd_cents(920, "EUR")
      end
    end
  end

  test "returns nil when all sources fail and no cache" do
    memory_store = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, memory_store) do
      CurrencyConversionService.stub(:fetch_from_primary, nil) do
        CurrencyConversionService.stub(:fetch_from_fallback, nil) do
          result = CurrencyConversionService.to_usd_cents(1000, "EUR")
          assert_nil result
        end
      end
    end
  end
end

class CurrencyConversionFetchTest < ActiveSupport::TestCase
  test "primary fetch parses rates from the API response" do
    body = { "rates" => { "USD" => 1.0, "EUR" => 0.92 } }.to_json
    CurrencyConversionService.stub(:http_get, body) do
      assert_equal({ "USD" => 1.0, "EUR" => 0.92 }, CurrencyConversionService.send(:fetch_from_primary))
    end
  end

  test "fallback fetch injects USD into frankfurter rates" do
    body = { "base" => "USD", "rates" => { "EUR" => 0.92, "RON" => 4.6 } }.to_json
    CurrencyConversionService.stub(:http_get, body) do
      rates = CurrencyConversionService.send(:fetch_from_fallback)
      assert_equal 1.0, rates["USD"]
      assert_equal 0.92, rates["EUR"]
    end
  end

  test "network failure on primary returns nil instead of raising" do
    CurrencyConversionService.stub(:http_get, ->(_url) { raise Net::OpenTimeout }) do
      assert_nil CurrencyConversionService.send(:fetch_from_primary)
    end
  end

  test "garbage response on fallback returns nil instead of raising" do
    CurrencyConversionService.stub(:http_get, "<html>error</html>") do
      assert_nil CurrencyConversionService.send(:fetch_from_fallback)
    end
  end

  test "fallback rates flow through to a real conversion" do
    memory_store = ActiveSupport::Cache::MemoryStore.new
    primary_down = lambda do |url|
      raise Net::OpenTimeout if url.include?("exchangerate-api")
      { "base" => "USD", "rates" => { "EUR" => 0.92 } }.to_json
    end

    Rails.stub(:cache, memory_store) do
      CurrencyConversionService.stub(:http_get, primary_down) do
        assert_equal 1000, CurrencyConversionService.to_usd_cents(920, "EUR")
      end
    end
    assert_equal 1.0, memory_store.read("exchange_rates_last_known")["USD"],
      "successful fallback must be stored as last-known-good"
  end

  test "supported_currencies lists rate keys" do
    memory_store = ActiveSupport::Cache::MemoryStore.new
    memory_store.write("exchange_rates", { "USD" => 1.0, "EUR" => 0.92 })

    Rails.stub(:cache, memory_store) do
      assert_includes CurrencyConversionService.supported_currencies, "EUR"
    end
  end
end
