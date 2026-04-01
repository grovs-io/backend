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
