# One fixed number from 0 to 99 per person and salt; Ruby and ClickHouse must agree, see SQL.
module Experiments::Bucket
  SQL = "(reinterpretAsUInt32(reverse(unhex(substring(hex(MD5(concat(%<salt>s, ':', toString(visitor_id)))), 1, 8)))) %% 100)".freeze

  module_function

  def of(salt, visitor_id) = Digest::MD5.hexdigest("#{salt}:#{visitor_id}")[0, 8].to_i(16) % 100

  def sql(salt_sql) = format(SQL, salt: salt_sql)
end
