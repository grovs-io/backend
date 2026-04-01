require 'connection_pool'

REDIS_POOL_SIZE = Integer(ENV.fetch('REDIS_POOL_SIZE', 15))

# Helper to create a fresh Redis connection pool. Called once at boot
# and again in each Puma worker after fork (see config/puma.rb).
def new_redis_pool
  ConnectionPool::Wrapper.new(size: REDIS_POOL_SIZE, timeout: 5) do
    Redis.new(url: ENV['REDIS_URL'], ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE })
  end
end

# ConnectionPool::Wrapper makes REDIS behave like a plain Redis object:
# each method call (lpush, set, get, eval, etc.) transparently checks out
# a connection from the pool, runs the command, and returns it.
#
# For pipelined/multi operations, use REDIS.with { |conn| conn.pipelined { ... } }
# to hold a single connection for the entire block.
REDIS = new_redis_pool
