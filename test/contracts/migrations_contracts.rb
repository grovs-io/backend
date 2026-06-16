require_relative "external_api_contracts"

module ApiContracts
  # credentials is intentionally absent — MigrationSourceSerializer excludes it.
  MIGRATION_SOURCE = strict_object(
    required: %w[id provider old_host enabled health consecutive_failures
                 first_failure_at last_error_status created_at updated_at],
    properties: {
      "id"                   => { "type" => "integer" },
      "provider"             => { "type" => "string", "enum" => %w[branch appsflyer] },
      "old_host"             => { "type" => "string" },
      "enabled"              => { "type" => "boolean" },
      "health"               => { "type" => "string", "enum" => %w[healthy degraded disabled] },
      "consecutive_failures" => { "type" => "integer" },
      "first_failure_at"     => STRING_OR_NULL,
      "last_error_status"    => INTEGER_OR_NULL,
      "created_at"           => STRING,
      "updated_at"           => STRING
    }
  )

  MIGRATION_CREDENTIALS_BRANCH = strict_object(
    required: %w[branch_key],
    properties: { "branch_key" => STRING }
  )

  MIGRATION_CREDENTIALS_APPSFLYER = strict_object(
    required: %w[onelink_id api_token],
    properties: { "onelink_id" => STRING, "api_token" => STRING }
  )

  # Cross-field provider/credentials shape match runs at the model layer (credentials_shape_for_provider).
  MIGRATION_CREDENTIALS_INPUT = {
    "oneOf" => [MIGRATION_CREDENTIALS_BRANCH, MIGRATION_CREDENTIALS_APPSFLYER]
  }.freeze

  migration_source_envelope = lambda do |nullable:|
    inner = MIGRATION_SOURCE.merge("type" => nullable ? %w[object null] : "object")
    {
      "type" => "object", "additionalProperties" => false,
      "required" => %w[migration_source],
      "properties" => { "migration_source" => inner }
    }
  end

  MIGRATIONS_CREATE_REQUEST = strict_object(
    required: %w[hostname provider credentials],
    properties: {
      "hostname"    => STRING,
      "provider"    => { "type" => "string", "enum" => %w[branch appsflyer] },
      "credentials" => MIGRATION_CREDENTIALS_INPUT
    }
  )

  MIGRATION_SOURCE_UPDATE_REQUEST = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => [],
    "properties" => {
      "enabled"     => { "type" => "boolean" },
      "credentials" => MIGRATION_CREDENTIALS_INPUT
    }
  }.freeze

  MIGRATION_TEST_RESPONSE = strict_object(
    required: %w[outcome http_status],
    properties: {
      "outcome" => {
        "type" => "string",
        "enum" => %w[credentials_ok credentials_invalid upstream_rate_limited
                     upstream_unreachable unexpected_success]
      },
      # 0 when no HTTP response was received (timeouts, etc.). Never nil.
      "http_status" => { "type" => "integer" }
    }
  )

  register "Api::V1::MigrationSourcesController#show",
           request: NO_PARAMS,
           responses: {
             200 => migration_source_envelope.call(nullable: true),
             401 => AUTH_ERROR, 403 => ERROR, 503 => ERROR
           }

  # CUSTOM_HOSTNAME is defined in custom_domains_contracts.rb; the contracts/**/*.rb
  # glob loads custom_ before migrations_.
  migrations_create_response = {
    "type" => "object", "additionalProperties" => false,
    "required" => %w[custom_domain migration_source],
    "properties" => {
      "custom_domain"    => CUSTOM_HOSTNAME,
      "migration_source" => MIGRATION_SOURCE
    }
  }.freeze

  register "Api::V1::MigrationsController#create",
           request: MIGRATIONS_CREATE_REQUEST,
           responses: {
             201 => migrations_create_response,
             402 => ERROR, 409 => ERROR, 422 => ERROR, 502 => ERROR, 404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR, 403 => ERROR, 503 => ERROR
           }

  register "Api::V1::MigrationSourcesController#update",
           request: MIGRATION_SOURCE_UPDATE_REQUEST,
           responses: {
             200 => migration_source_envelope.call(nullable: false),
             422 => ERROR, 404 => ERROR,
             401 => AUTH_ERROR, 403 => ERROR, 503 => ERROR
           }

  register "Api::V1::MigrationSourcesController#destroy",
           request: NO_PARAMS,
           responses: {
             200 => MESSAGE, 404 => ERROR,
             401 => AUTH_ERROR, 403 => ERROR, 503 => ERROR
           }

  register "Api::V1::MigrationSourcesController#test",
           request: NO_PARAMS,
           responses: {
             200 => MIGRATION_TEST_RESPONSE,
             404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR, 403 => ERROR, 503 => ERROR
           }
end
