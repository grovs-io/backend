# Under transactional fixtures, after_commit :clear_cache fires BEFORE the rollback,
# leaving the Redis model cache pointing at whatever a sibling test flipped acme_active to.
module MigrationFixtureHelpers
  def reset_acme_active_to_active!
    ch = custom_hostnames(:acme_active)
    ch.update_columns(status: "active", ssl_status: "active",
                      project_id: projects(:one).id, domain_id: domains(:one).id)
    ch.send(:clear_cache)
    ch
  end
end
