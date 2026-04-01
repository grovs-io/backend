class RedirectSerializer < BaseSerializer
  attributes :redirect_config_id, :platform, :variation, :enabled, :appstore, :fallback_url
end
