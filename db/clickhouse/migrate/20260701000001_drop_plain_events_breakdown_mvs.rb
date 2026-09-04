# frozen_string_literal: true

# Consolidation: the breakdown rollups (project_daily / link_daily / visitor_daily
# / project_country_daily / project_version_daily / project_source_daily /
# project_property_daily / billing_active_visitors_daily) are now recomputed from
# the deduped events_canonical by ClickhouseRollupRebuildService (exact + merge-
# aware), replacing these plain-events MVs. The MVs fired pre-dedup and were
# merge-blind, so they double-counted retries and ignored visitor merges.
#
# The TARGET TABLES are kept and keep their schema/readers — only the population
# mechanism changes (MV -> rebuild). Dropping an MV does not touch the table it
# fed. Forward-only, idempotent.
class DropPlainEventsBreakdownMvs < Clickhouse::Migration
  MVS = %w[
    mv_project_daily
    mv_link_daily
    mv_visitor_daily
    mv_project_country_daily
    mv_project_version_daily
    mv_project_source_daily
    mv_project_property_daily
    mv_billing_active_visitors_daily
  ].freeze

  def up
    MVS.each { |mv| execute("DROP TABLE IF EXISTS `#{mv}`") }
  end
end
