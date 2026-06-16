module MigrationProviderClient
  def self.for(source)
    case source.provider
    when Grovs::Migrations::PROVIDER_BRANCH    then BranchMigrationClient.new(source)
    when Grovs::Migrations::PROVIDER_APPSFLYER then AppsflyerMigrationClient.new(source)
    else
      raise ArgumentError, "Unknown migration provider: #{source.provider.inspect}"
    end
  end
end
