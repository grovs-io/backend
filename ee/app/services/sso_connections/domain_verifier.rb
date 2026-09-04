module SsoConnections
  module DomainVerifier
    class AlreadyClaimed < StandardError; end

    module_function

    def default_resolver = Resolv::DNS.new.tap { |r| r.timeouts = [2, 3] }

    def verify!(domain_row, resolver: default_resolver)
      values = resolver.getresources(domain_row.record_name, Resolv::DNS::Resource::IN::TXT).flat_map(&:strings)
      return false unless values.include?(domain_row.record_value)

      domain_row.update!(verified_at: Time.current)
      true
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyClaimed
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, SocketError, IOError
      false
    end
  end
end
