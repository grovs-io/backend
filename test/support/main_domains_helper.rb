module MainDomainsHelper
  # Swap Grovs::Domains::MAIN for a block — lets tests exercise nested (3+ label)
  # self-hosted domains without touching ENV or reloading the app.
  # Swaps MAIN only: production code must read MAIN live (never memoize from it).
  def with_main_domains(domains)
    original = Grovs::Domains::MAIN
    Grovs::Domains.send(:remove_const, :MAIN)
    Grovs::Domains.const_set(:MAIN, domains.dup.freeze)
    yield
  ensure
    Grovs::Domains.send(:remove_const, :MAIN)
    Grovs::Domains.const_set(:MAIN, original)
  end
end
