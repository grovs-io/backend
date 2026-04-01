unless Rails.env.development? || Rails.env.test?
  require 'opentelemetry/sdk'
  require 'opentelemetry/exporter/otlp'
  require 'opentelemetry/instrumentation/all'
  require 'opentelemetry/semantic_conventions'

  # Determine process type
  process_type = if defined?(Sidekiq) && Sidekiq.server?
    'worker'
  elsif $PROGRAM_NAME.include?('sidekiq')
    'worker'
  else
    'web'
  end

  # Get hostname
  hostname = begin; Socket.gethostname; rescue SystemCallError; 'unknown'; end

  OpenTelemetry::SDK.configure do |c|
    c.service_name = ENV.fetch('OTEL_SERVICE_NAME', "grovs-#{Rails.env}")
    c.service_version = ENV.fetch('APP_VERSION', 'unknown')

    # Add resource attributes for better filtering in Signoz
    c.resource = OpenTelemetry::SDK::Resources::Resource.create({
      'host.name' => hostname,
      'host.id' => hostname,
      'process.type' => process_type,
      'deployment.environment' => Rails.env.to_s,
      'service.namespace' => 'grovs',
      'service.instance.id' => "#{hostname}-#{process_type}-#{Process.pid}",
      # Kubernetes-style labels (Signoz uses these)
      'k8s.pod.name' => hostname,
      'k8s.namespace.name' => Rails.env.to_s
    })

    # Auto-instrument everything: Rails, ActiveRecord, Redis, Sidekiq, Net::HTTP, etc.
    c.use_all({
      'OpenTelemetry::Instrumentation::Rails' => {
        # Record exceptions with full details
        record_exceptions: true,
        # Enable request/response hooks
        enable_recognize_route: true
      },
      'OpenTelemetry::Instrumentation::ActionPack' => {
        # Better controller span names
        enable_recognize_route: true
      },
      'OpenTelemetry::Instrumentation::ActiveRecord' => {
        # Capture SQL queries in spans
        db_statement: :include,
        # Add database attributes
        peer_service: 'postgresql'
      },
      'OpenTelemetry::Instrumentation::Redis' => {
        # Capture Redis commands
        db_statement: :include,
        peer_service: 'redis'
      },
      'OpenTelemetry::Instrumentation::Sidekiq' => {
        # Trace Sidekiq jobs with class name
        span_naming: :job_class,
        # Propagate trace context to jobs
        propagation_style: :link
      },
      'OpenTelemetry::Instrumentation::Net::HTTP' => {
        untraced_hosts: ['metadata.google.internal'],
      },
      'OpenTelemetry::Instrumentation::Rack' => {
        # Don't trace health check endpoints
        untraced_endpoints: ['/up', '/health', '/favicon.ico'],
        # Record exceptions
        record_frontend_span: true
      },
      'OpenTelemetry::Instrumentation::PG' => {
        # PostgreSQL driver instrumentation
        db_statement: :include,
        peer_service: 'postgresql'
      }
    })

    # Configure OTLP exporter if endpoint is set
    if ENV['OTEL_EXPORTER_OTLP_ENDPOINT'].present?
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
          OpenTelemetry::Exporter::OTLP::Exporter.new(
            endpoint: "#{ENV['OTEL_EXPORTER_OTLP_ENDPOINT']}/v1/traces",
            headers: {}
          )
        )
      )
      service_name = ENV.fetch('OTEL_SERVICE_NAME', "grovs-#{Rails.env}")
      Rails.logger.info "[OpenTelemetry] Configured: service=#{service_name}, host=#{hostname}, process=#{process_type}, endpoint=#{ENV['OTEL_EXPORTER_OTLP_ENDPOINT']}"
    else
      Rails.logger.warn "[OpenTelemetry] OTEL_EXPORTER_OTLP_ENDPOINT not set, traces will not be exported"
    end
  end

  # Add custom exception handler to enrich spans with error details
  if defined?(ActiveSupport::Notifications)
    ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      if event.payload[:exception_object]
        exception = event.payload[:exception_object]

        # Skip RecordNotFound for ActiveStorage — handled by middleware with a 404
        next if exception.is_a?(ActiveRecord::RecordNotFound) &&
                exception.model == 'ActiveStorage::Blob'

        span = OpenTelemetry::Trace.current_span
        span.record_exception(exception)
        span.set_attribute('error.type', exception.class.name)
        span.set_attribute('error.message', exception.message)
        error_hostname = begin; Socket.gethostname; rescue SystemCallError; 'unknown'; end
        span.set_attribute('error.hostname', error_hostname)
        span.status = OpenTelemetry::Trace::Status.error(exception.message)
      end
    end
  end
end
