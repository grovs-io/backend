require "json-schema"

JSON::Validator.use_multi_json = false # use the stdlib JSON parser (avoids a deprecation)

# Strict request/response contract lock for the JSON API.
#
# Same spirit as CacheKeyCoverageTest: a registry of per-endpoint schemas plus a
# coverage gate (ApiContractCoverageTest) that fails if any app endpoint is neither
# contracted nor explicitly listed as pending. Contracts are keyed by
# "Controller#action" (robust against the subdomain-based routing — no path
# matching). Once an action is registered, EVERY request and response a test makes
# to it is validated strictly: schemas use additionalProperties:false + required, so
# an added, removed, renamed, or retyped param/field fails the suite.
#
# Rollout is incremental: the per-request hook only validates actions that have a
# contract, so locking one endpoint never breaks the others. The gate tracks the
# remaining backlog so nothing is silently left uncovered.
module ApiContracts
  class ContractError < StandardError; end

  Contract = Struct.new(:request, :responses, keyword_init: true)

  @registry = {}

  class << self
    # request:   JSON schema (Hash) for body+query params, or nil to skip input checks.
    # responses: { Integer status => Hash schema | :any }. :any accepts any body and
    #            is reserved for framework-owned envelopes (e.g. Doorkeeper's 401),
    #            which are not part of the endpoint's own contract.
    def register(action, responses:, request: nil)
      raise ArgumentError, "duplicate contract for #{action}" if @registry.key?(action)

      @registry[action] = Contract.new(request: request, responses: responses)
    end

    def registered?(action) = @registry.key?(action)
    def actions = @registry.keys
    def contracts = @registry.dup

    # Called after every integration request. No-op unless the handled action has a
    # contract, so the lock can be rolled out one endpoint at a time.
    def validate_last!(test)
      return if ENV["SKIP_API_CONTRACTS"] == "true"

      controller = test.controller
      return if controller.nil? # routing errors / rack middleware (rate limiting, etc.)

      action = "#{controller.class.name}##{controller.action_name}"
      contract = @registry[action]
      return if contract.nil?

      validate_request!(action, contract, test.request)
      validate_response!(action, contract, test.response)
    end

    private

    def validate_request!(action, contract, request)
      return if contract.request.nil?

      input = normalize(request.request_parameters).merge(normalize(request.query_parameters))
      errors = JSON::Validator.fully_validate(contract.request, input)
      return if errors.empty?

      raise ContractError, "[#{action}] request violates contract:\n  #{errors.join("\n  ")}\n  input: #{input.inspect}"
    rescue ActionDispatch::Http::Parameters::ParseError
      # Malformed JSON bodies are framework-owned parse failures; response
      # contracts still validate the endpoint's explicit error behavior.
      nil
    end

    def validate_response!(action, contract, response)
      status = response.status
      unless contract.responses.key?(status)
        raise ContractError,
              "[#{action}] response status #{status} is not in the contract. " \
              "Add it to the responses map.\n  body: #{response.body.to_s[0, 300]}"
      end

      schema = contract.responses[status]
      return if ApiContracts.unchecked?(schema)

      body = parse_body(response)
      errors = JSON::Validator.fully_validate(schema, body)
      return if errors.empty?

      raise ContractError, "[#{action}] #{status} response violates contract:\n  #{errors.join("\n  ")}\n  body: #{body.inspect}"
    end

    def parse_body(response)
      raw = response.body.to_s
      raw.empty? ? {} : JSON.parse(raw)
    rescue JSON::ParserError
      raise ContractError, "response body is not valid JSON: #{response.body.to_s[0, 200]}"
    end

    # Coerce ActionController::Parameters / symbol keys / nested objects to plain
    # JSON types so json-schema validates them consistently.
    def normalize(params)
      JSON.parse(params.to_h.to_json)
    end
  end

  # Validates the last response after each integration request. Prepended onto
  # ActionDispatch::IntegrationTest so it applies to every integration test with no
  # per-test wiring.
  module IntegrationHook
    %i[get post put patch delete head].each do |verb|
      define_method(verb) do |*args, **kwargs, &blk|
        result = super(*args, **kwargs, &blk)
        ApiContracts.validate_last!(self)
        result
      end
    end
  end
end
