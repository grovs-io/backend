require_relative "external_api_contracts"

module ApiContracts
  # ssl_* fields are required-but-nullable so the FE always sees the keys; legacy/HTTP-01 rows carry null.
  # Each entry of `ssl_validation_txt_records` is a CF ACME challenge for ONE cert
  # authority. CF can emit multiple when doing multi-CA dual issuance (one TXT per CA,
  # both must resolve at DNS for both certs to issue) and can add/rotate entries at
  # any point in the lifecycle. Empty array = nothing to do (post-activation, or
  # never-emitted on HTTP-01 zones).
  SSL_VALIDATION_TXT_RECORD = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[name value],
    "properties" => {
      "name"  => STRING_OR_NULL,
      "value" => STRING_OR_NULL
    }
  }.freeze

  CUSTOM_HOSTNAME = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[hostname status ssl_status verification_errors source purpose
                     ssl_method ssl_validation_txt_records
                     ownership_verification_txt_name ownership_verification_txt_value
                     last_checked_at cname_target],
    "properties" => {
      "hostname"                         => { "type" => "string" },
      "status"                           => { "type" => "string" },
      "ssl_status"                       => { "type" => %w[string null] },
      "verification_errors"              => { "type" => %w[string null] },
      "source"                           => { "type" => "string" },
      "purpose"                          => { "type" => "string", "enum" => Grovs::Hostnames::PURPOSES },
      "ssl_method"                       => STRING_OR_NULL,
      # Canonical multi-record store; FE iterates and renders each entry. Empty array
      # means "nothing for the customer to add right now" (post-activation, fresh
      # provisioning, or HTTP-01 path).
      "ssl_validation_txt_records"       => { "type" => "array", "items" => SSL_VALIDATION_TXT_RECORD },
      "ownership_verification_txt_name"  => STRING_OR_NULL,
      "ownership_verification_txt_value" => STRING_OR_NULL,
      # FE renders "Last checked from Cloudflare: N seconds ago" so the customer can
      # see whether the displayed records are fresh or worth a manual refresh.
      "last_checked_at"                  => { "type" => %w[string null] },
      "cname_target"                     => { "type" => "string" }
    }
  }.freeze

  HOSTNAME_REQUEST = { "type" => "object", "additionalProperties" => false,
                       "required" => %w[hostname], "properties" => { "hostname" => { "type" => "string" } } }.freeze

  CUSTOM_DOMAIN_CREATE_V2_REQUEST = strict_object(
    required: %w[hostname purpose],
    properties: {
      "hostname" => STRING,
      "purpose"  => { "type" => "string", "enum" => Grovs::Hostnames::PURPOSES }
    }
  )

  CUSTOM_DOMAIN_DELETE_V2_REQUEST = strict_object(
    required: %w[purpose],
    properties: {
      "purpose" => { "type" => "string", "enum" => Grovs::Hostnames::PURPOSES }
    }
  )

  CUSTOM_DOMAIN_PREFLIGHT_REQUEST = strict_object(
    required: %w[hostname],
    properties: {
      "hostname" => STRING
    }
  )

  CUSTOM_DOMAIN_PREFLIGHT_RESPONSE = strict_object(
    required: %w[hostname cname_expected cname_actual cname_matches checked_at],
    properties: {
      "hostname"       => STRING,
      "cname_expected" => STRING_OR_NULL,
      "cname_actual"   => STRING_OR_NULL,
      "cname_matches"  => { "type" => "boolean" },
      "checked_at"     => STRING,
      "dns_error"      => STRING
    }
  )

  custom_domain_envelope = lambda do |nullable:|
    inner = CUSTOM_HOSTNAME.merge("type" => nullable ? %w[object null] : "object")
    { "type" => "object", "additionalProperties" => false,
      "required" => %w[custom_domain], "properties" => { "custom_domain" => inner } }
  end

  custom_domains_index_response = {
    "type" => "object", "additionalProperties" => false,
    "required" => %w[custom_domains],
    "properties" => {
      "custom_domains" => { "type" => "array", "items" => CUSTOM_HOSTNAME }
    }
  }.freeze

  register "Api::V1::DomainsController#custom_domain",
           request: NO_PARAMS,
           responses: {
             200 => custom_domain_envelope.call(nullable: true),
             404 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#create_custom_domain",
           request: HOSTNAME_REQUEST,
           responses: {
             201 => custom_domain_envelope.call(nullable: false),
             402 => ERROR, 422 => ERROR, 409 => ERROR, 502 => ERROR, 404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#delete_custom_domain",
           request: NO_PARAMS,
           responses: {
             200 => MESSAGE, 202 => MESSAGE, 404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#index_custom_domains",
           request: NO_PARAMS,
           responses: {
             200 => custom_domains_index_response,
             404 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#create_custom_domain_v2",
           request: CUSTOM_DOMAIN_CREATE_V2_REQUEST,
           responses: {
             201 => custom_domain_envelope.call(nullable: false),
             402 => ERROR, 422 => ERROR, 409 => ERROR, 502 => ERROR, 404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#delete_custom_domain_v2",
           request: CUSTOM_DOMAIN_DELETE_V2_REQUEST,
           responses: {
             200 => MESSAGE, 202 => MESSAGE, 422 => ERROR, 404 => ERROR,
             429 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::DomainsController#preflight_custom_domain",
           request: CUSTOM_DOMAIN_PREFLIGHT_REQUEST,
           responses: {
             200 => CUSTOM_DOMAIN_PREFLIGHT_RESPONSE,
             422 => ERROR,
             404 => ERROR,
             429 => ERROR,
             403 => ERROR,
             401 => AUTH_ERROR
           }

  register "Api::V1::AdminController#create_custom_domain",
           request: { "type" => "object", "additionalProperties" => false,
                      "required" => %w[hostname project_id],
                      "properties" => { "hostname" => { "type" => "string" },
                                        "project_id" => { "type" => %w[string integer] },
                                        "purpose" => { "type" => "string", "enum" => Grovs::Hostnames::PURPOSES } } },
           responses: {
             201 => custom_domain_envelope.call(nullable: false),
             402 => ERROR, 422 => ERROR, 409 => ERROR, 502 => ERROR, 404 => ERROR,
             403 => ERROR
           }
end
