require 'net/http'
require 'json'

class CurrencyConversionService
  PRIMARY_API_URL = 'https://open.exchangerate-api.com/v6/latest'.freeze
  FALLBACK_API_URL = 'https://api.frankfurter.dev/v1/latest?base=USD'.freeze
  REFRESH_INTERVAL = 1.hour.freeze

  def self.to_usd_cents(amount_in_cents, from_currency)
    return amount_in_cents if from_currency.upcase == 'USD'

    exchange_rates = get_rates
    from_currency = from_currency.upcase

    unless exchange_rates.key?(from_currency)
      Rails.logger.error "Unsupported currency: #{from_currency}"
      return nil
    end

    rate = exchange_rates[from_currency]
    (amount_in_cents.to_f / rate).round
  rescue ArgumentError, TypeError, ZeroDivisionError => e
    Rails.logger.error "Currency conversion error: #{e.class} - #{e.message}"
    nil
  end

  def self.supported_currencies
    get_rates.keys
  end

  private

  # Two-layer cache: try to refresh every hour, but always keep the last known good rates.
  # A day-old rate is 99.9% accurate. nil is 0% accurate.
  def self.get_rates
    # Try to get fresh rates (cached for REFRESH_INTERVAL)
    rates = Rails.cache.fetch("exchange_rates", expires_in: REFRESH_INTERVAL) do
      fresh = fetch_from_primary || fetch_from_fallback
      if fresh
        # Store as "last known good" — this key never expires
        Rails.cache.write("exchange_rates_last_known", fresh)
        fresh
      else
        # Fetch failed — don't cache the failure (return nil so cache.fetch retries next time)
        nil
      end
    end

    # If fresh fetch failed (nil), fall back to last known good rates
    rates || Rails.cache.read("exchange_rates_last_known") || {}
  end

  def self.fetch_from_primary
    response = http_get(PRIMARY_API_URL)
    data = JSON.parse(response)
    data['rates']
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError,
         JSON::ParserError => e
    Rails.logger.warn "Primary exchange rate API failed: #{e.class} - #{e.message}"
    nil
  end

  def self.fetch_from_fallback
    response = http_get(FALLBACK_API_URL)
    data = JSON.parse(response)
    # Frankfurter returns { "base": "USD", "rates": { "EUR": 0.92, ... } }
    # but doesn't include USD itself
    rates = data['rates'] || {}
    rates['USD'] = 1.0
    rates
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError,
         Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError,
         JSON::ParserError => e
    Rails.logger.warn "Fallback exchange rate API failed: #{e.class} - #{e.message}"
    nil
  end

  def self.http_get(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 3
    http.read_timeout = 3
    http.get(uri.request_uri).body
  end
end
