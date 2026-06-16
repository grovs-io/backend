# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # Migrate-from-competitors credentials blob: {branch_key, onelink_id, api_token}.
  # branch_key/api_token are caught by :_key / :token; onelink_id is NOT (no shared
  # suffix), so add the whole `credentials` blob filter as a belt-and-suspenders.
  :credentials, :onelink_id
]
