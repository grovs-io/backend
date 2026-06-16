# Shared schemas for strict API contracts. Keep these small and boring: endpoint
# contract files compose them, but each endpoint still declares its own response
# envelope explicitly.
module ApiContracts
  UncheckedSchema = Struct.new(:reason, keyword_init: true)

  def self.unchecked(reason)
    UncheckedSchema.new(reason: reason).freeze
  end

  def self.unchecked?(schema)
    schema.is_a?(UncheckedSchema)
  end

  def self.strict_object(required:, properties:)
    {
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }.freeze
  end

  NO_PARAMS = {
    "type" => "object",
    "additionalProperties" => false,
    "properties" => {}
  }.freeze

  ANY_OBJECT = {
    "type" => "object"
  }.freeze

  ERROR = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[error],
    "properties" => {
      "error" => { "type" => "string" }
    }
  }.freeze

  ERROR_WITH_MESSAGE = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[error],
    "properties" => {
      "error" => { "type" => "string" },
      "message" => { "type" => "string" }
    }
  }.freeze

  MESSAGE = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[message],
    "properties" => {
      "message" => { "type" => "string" }
    }
  }.freeze

  AUTH_ERROR = {
    "type" => "object",
    "additionalProperties" => true,
    "required" => [],
    "properties" => {
      "error" => { "type" => "string" },
      "error_description" => { "type" => "string" },
      "message" => { "type" => "string" }
    }
  }.freeze

  RAILS_EXCEPTION_RESPONSE = {
    "type" => "object",
    "additionalProperties" => false,
    "required" => %w[status error],
    "properties" => {
      "status" => { "type" => "integer" },
      "error" => { "type" => "string" },
      "exception" => { "type" => "string" },
      "traces" => { "type" => "object" }
    }
  }.freeze

  REDIRECT_RESPONSE = unchecked("HTTP redirect response; Location/status are the contract, body is not API JSON")
  NON_JSON_RESPONSE = unchecked("Non-JSON public response body")

  ID = { "type" => %w[integer string] }.freeze
  STRING = { "type" => "string" }.freeze
  NULLABLE_STRING = { "type" => %w[string null] }.freeze
  BOOL = { "type" => %w[boolean string] }.freeze
  NUMBER = { "type" => %w[number integer] }.freeze
  ARRAY = { "type" => "array" }.freeze
  JSON_VALUE = {}.freeze
  STRING_OR_NULL = { "type" => %w[string null] }.freeze
  INTEGER_OR_NULL = { "type" => %w[integer null] }.freeze
  BOOLEAN_OR_NULL = { "type" => %w[boolean null] }.freeze
  BOOL_OR_NULL = { "type" => %w[boolean string null] }.freeze
  ARRAY_OR_NULL = { "type" => %w[array null] }.freeze
  OBJECT_OR_NULL = { "type" => %w[object null] }.freeze
end
