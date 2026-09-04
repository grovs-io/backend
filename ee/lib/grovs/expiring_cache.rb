module Grovs
  # SWD passes no expiry; the deep copy keeps memory stores from sharing a memoized JWKS.
  class ExpiringCache
    def initialize(expires_in:)
      @expires_in = expires_in
    end

    def fetch(key, _options = {}, &block)
      value = Rails.cache.fetch("swd:#{key}", expires_in: @expires_in, &block)
      Marshal.load(Marshal.dump(value))
    end
  end
end
