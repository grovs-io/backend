# frozen_string_literal: true

# Schema validation helper for MCP endpoints.
# Every MCP response is validated against these schemas so that
# additions, removals, or type changes in the API surface are caught
# automatically by the test suite.
#
# Usage:
#   include McpSchemaHelper
#   assert_response_schema :token_response
#   assert_response_schema :token_response, parsed_json   # pre-parsed
#   assert_each_item_schema :token_list_item, json["tokens"]
module McpSchemaHelper
  # ---------------------------------------------------------------------------
  # Type DSL
  # ---------------------------------------------------------------------------
  #   :string           non-nil, non-blank String
  #   :string?          String or nil
  #   :integer          non-nil Integer
  #   :integer?         Integer or nil
  #   :boolean          true | false
  #   :boolean?         true | false | nil
  #   :array            Array (inner items validated separately)
  #   :hash?            Hash or nil (inner validated separately)
  #   :any              non-nil value
  #   [:string]         Array of Strings
  #   { "k" => :type }  nested Hash validated recursively
  # ---------------------------------------------------------------------------

  # =========================================================================
  # Output Schemas — one per distinct response shape
  # =========================================================================
  SCHEMAS = {
    # GET /.well-known/oauth-protected-resource
    protected_resource_metadata: {
      "resource" => :string,
      "authorization_servers" => [:string],
      "scopes_supported" => [:string]
    },

    # GET /.well-known/oauth-authorization-server
    authorization_server_metadata: {
      "issuer" => :string,
      "authorization_endpoint" => :string,
      "token_endpoint" => :string,
      "registration_endpoint" => :string,
      "response_types_supported" => [:string],
      "grant_types_supported" => [:string],
      "code_challenge_methods_supported" => [:string],
      "token_endpoint_auth_methods_supported" => [:string],
      "scopes_supported" => [:string]
    },

    # POST /register  (RFC 7591 dynamic client registration)
    client_registration: {
      "client_id" => :string,
      "client_name" => :string,
      "redirect_uris" => [:string],
      "grant_types" => [:string],
      "response_types" => [:string],
      "token_endpoint_auth_method" => :string,
      "application_type" => :string
    },

    # POST /token  (authorization_code or refresh_token grant)
    token_response: {
      "access_token" => :string,
      "token_type" => :string,
      "expires_in" => :integer,
      "refresh_token" => :string,
      "scope" => :string?
    },

    # POST /api/v1/mcp/approve_consent
    consent_response: {
      "code" => :string,
      "redirect_uri" => :string,
      "state" => :string?
    },

    # GET /api/v1/mcp/status
    status_response: {
      "user" => {
        "id" => :integer,
        "email" => :string,
        "name" => :string
      },
      "instances" => :array
    },

    # Each element of status_response["instances"]
    instance_status: {
      "id" => :string,
      "name" => :string,
      "uri_scheme" => :string?,
      "production" => :hash?,
      "test" => :hash?,
      "configurations" => {
        "ios" => :boolean,
        "android" => :boolean,
        "web" => :boolean,
        "desktop" => :boolean
      },
      "usage" => {
        "current_mau" => :integer,
        "mau_limit" => :integer,
        "quota_exceeded" => :boolean,
        "has_subscription" => :boolean
      }
    },

    # Nested project inside instance_status
    project_status: {
      "id" => :string,
      "name" => :string,
      "identifier" => :string,
      "test" => :boolean,
      "domain" => :string?,
      "has_redirect_config" => :boolean,
      "has_links" => :boolean
    },

    # GET /api/v1/mcp/tokens
    tokens_list: {
      "tokens" => :array
    },

    # Each element of tokens_list["tokens"]
    token_list_item: {
      "id" => :string,
      "name" => :string,
      "client_id" => :string?,
      "created_at" => :string,
      "last_used_at" => :string?
    },

    # Standard OAuth error (error only)
    oauth_error: {
      "error" => :string
    },

    # OAuth error with description
    oauth_error_with_description: {
      "error" => :string,
      "error_description" => :string
    },

    # Simple { "error": "..." }
    simple_error: {
      "error" => :string
    },

    # Simple { "message": "..." }
    simple_message: {
      "message" => :string
    }
  }.freeze

  # =========================================================================
  # Input Schemas — documents required params per endpoint.
  # Used by assert_rejects_missing_params to verify the endpoint actually
  # enforces each required field.
  # =========================================================================
  INPUT_SCHEMAS = {
    # POST /register
    register: {
      required: %w[client_name redirect_uris],
      optional: %w[grant_types response_types token_endpoint_auth_method application_type client_uri logo_uri]
    },

    # GET /authorize
    authorize: {
      required: %w[client_id redirect_uri response_type code_challenge code_challenge_method],
      optional: %w[state scope]
    },

    # POST /token (authorization_code)
    token_authorization_code: {
      required: %w[grant_type code redirect_uri client_id code_verifier],
      optional: %w[]
    },

    # POST /token (refresh_token)
    token_refresh: {
      required: %w[grant_type refresh_token],
      optional: %w[client_id]
    },

    # POST /api/v1/mcp/approve_consent
    approve_consent: {
      required: %w[redirect_uri client_id code_challenge code_challenge_method],
      optional: %w[state scope]
    }
  }.freeze

  # ---------------------------------------------------------------------------
  # Assertions
  # ---------------------------------------------------------------------------

  # Validate JSON body matches the named schema.  Fails on missing keys,
  # wrong types, and (in strict mode) unexpected keys.
  def assert_response_schema(schema_name, json = nil, strict: true)
    json ||= JSON.parse(response.body)
    schema = SCHEMAS.fetch(schema_name) { flunk "Unknown schema: #{schema_name}" }
    validate_object(json, schema, path: schema_name.to_s, strict: strict)
    json
  end

  # Validate every item in an array against a schema.
  def assert_each_item_schema(schema_name, items)
    schema = SCHEMAS.fetch(schema_name) { flunk "Unknown schema: #{schema_name}" }
    assert_kind_of Array, items, "expected Array for #{schema_name} items"
    items.each_with_index do |item, i|
      validate_object(item, schema, path: "#{schema_name}[#{i}]", strict: true)
    end
  end

  private

  def validate_object(obj, schema, path:, strict: true)
    assert_kind_of Hash, obj, "#{path}: expected Hash, got #{obj.class} (#{obj.inspect[0..100]})"

    schema.each do |key, type_spec|
      optional = nullable_type?(type_spec)
      unless optional || obj.key?(key)
        flunk "#{path}: missing required key '#{key}'. Present keys: #{obj.keys.sort}"
      end
      validate_value(obj[key], type_spec, path: "#{path}.#{key}") if obj.key?(key)
    end

    if strict
      extra = obj.keys - schema.keys
      if extra.any?
        flunk "#{path}: unexpected keys #{extra.inspect} — response schema may have changed. " \
              "Update McpSchemaHelper::SCHEMAS[:#{path.split('.').first}] if this is intentional."
      end
    end
  end

  def validate_value(value, type_spec, path:)
    case type_spec
    when :string
      assert_not_nil value, "#{path}: expected String, got nil"
      assert_kind_of String, value, "#{path}: expected String, got #{value.class}"
      assert value.present?, "#{path}: expected non-blank String"
    when :string?
      assert(value.nil? || value.is_a?(String), "#{path}: expected String or nil, got #{value.class}")
    when :integer
      assert_not_nil value, "#{path}: expected Integer, got nil"
      assert_kind_of Integer, value, "#{path}: expected Integer, got #{value.class}"
    when :integer?
      assert(value.nil? || value.is_a?(Integer), "#{path}: expected Integer or nil, got #{value.class}")
    when :boolean
      assert [true, false].include?(value), "#{path}: expected boolean, got #{value.inspect}"
    when :boolean?
      assert [true, false, nil].include?(value), "#{path}: expected boolean or nil, got #{value.inspect}"
    when :array
      assert_kind_of Array, value, "#{path}: expected Array, got #{value.class}"
    when :hash?
      assert(value.nil? || value.is_a?(Hash), "#{path}: expected Hash or nil, got #{value.class}")
    when :any
      assert_not_nil value, "#{path}: expected non-nil value"
    when Array
      assert_kind_of Array, value, "#{path}: expected Array, got #{value.class}"
      inner = type_spec.first
      value.each_with_index do |item, i|
        validate_value(item, inner, path: "#{path}[#{i}]")
      end
    when Hash
      validate_object(value, type_spec, path: path, strict: true)
    else
      flunk "#{path}: unknown type_spec #{type_spec.inspect}"
    end
  end

  def nullable_type?(spec)
    return true if spec.is_a?(Symbol) && spec.to_s.end_with?("?")
    false
  end
end
