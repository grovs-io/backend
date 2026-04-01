function classify_log(tag, ts, record)
    local log = record["log"]

    if type(log) ~= "string" then
        record["body"] = "invalid log"
        record["severity_text"] = "INFO"
        record["severity_number"] = 9
        return 1, ts, record
    end

    -- Clean the log message (remove trailing newlines)
    log = log:gsub("%s+$", "")

    -- Initialize default fields
    record["body"] = log
    record["severity_text"] = "INFO"
    record["severity_number"] = 9

    -- Get service metadata from record (set by content_modifier)
    local service_name = record["service_name"] or "grovs"
    local environment = record["deployment_environment"] or "unknown"
    local host_name = record["host_name"] or "unknown"
    local host_ip = record["host_ip"] or "unknown"
    local container_name = record["container_name"] or "unknown"
    local service_role = record["service_role"] or extract_service_role(tag)

    -- Initialize attributes
    local attributes = {}

    -- Add service metadata to attributes
    attributes["service_name"] = service_name
    attributes["environment"] = environment
    attributes["host_name"] = host_name
    attributes["host_ip"] = host_ip
    attributes["container_name"] = container_name
    attributes["service_role"] = service_role

    -- Extract trace context from JSON log (for OTEL correlation)
    local trace_id = log:match('"trace_id"%s*:%s*"([a-f0-9]+)"')
    local span_id = log:match('"span_id"%s*:%s*"([a-f0-9]+)"')
    local trace_flags = log:match('"trace_flags"%s*:%s*(%d+)')

    if trace_id and trace_id ~= "" then
        record["trace_id"] = trace_id
    end
    if span_id and span_id ~= "" then
        record["span_id"] = span_id
    end
    if trace_flags then
        record["trace_flags"] = tonumber(trace_flags) or 0
    end

    -- First, try to parse as JSON log (Lograge/structured format)
    -- Format: {"timestamp":"...","level":"ERROR","message":"...","service":"..."}
    local json_level = log:match('"level"%s*:%s*"([^"]+)"')
    if json_level then
        -- This is a JSON structured log
        attributes["log_type"] = "json_structured"

        -- Set severity based on level field
        local severity = map_level_to_severity(json_level)
        record["severity_text"] = severity.text
        record["severity_number"] = severity.number

        -- Extract other JSON fields
        local json_message = log:match('"message"%s*:%s*"(.-)"[,}]')
        if json_message then
            -- Unescape the message (it might contain escaped JSON)
            json_message = json_message:gsub('\\"', '"')
            attributes["message"] = json_message

            -- Try to parse nested JSON in message
            if json_message:match('^{.*}$') then
                local inner_data = parse_json(json_message)
                if inner_data then
                    if inner_data.http_method or inner_data.method then
                        attributes["http_method"] = inner_data.http_method or inner_data.method
                    end
                    if inner_data.controller then attributes["controller"] = inner_data.controller end
                    if inner_data.action then attributes["action"] = inner_data.action end
                    if inner_data.status then
                        attributes["http_status"] = tostring(inner_data.status)
                        attributes["http_status_code"] = inner_data.status
                    end
                    if inner_data.duration then attributes["duration_ms"] = inner_data.duration end
                    if inner_data.path then attributes["http_path"] = inner_data.path end
                    if inner_data.request_ip or inner_data.ip then
                        attributes["client_ip"] = inner_data.request_ip or inner_data.ip
                    end
                    if inner_data.error_class then attributes["error_class"] = inner_data.error_class end
                    if inner_data.error_message then attributes["error_message"] = inner_data.error_message end
                end
            end
        end

        -- Set attributes and return
        attributes["meta"] = "fluentbit"
        record["attributes"] = attributes
        return 1, ts, record
    end

    -- Parse Rails log structure (text format)
    local level, timestamp, pid, log_severity, message = log:match("^([IWEF]), %[([^%]]+) #(%d+)%]%s+(%w+)%s+%-%-%s+:%s+(.*)$")
    
    if level and timestamp and pid and log_severity and message then
        -- This is a Rails log
        attributes["log_type"] = "rails"
        attributes["rails_level"] = level
        attributes["pid"] = tonumber(pid)
        attributes["message"] = message
        
        -- Set severity based on Rails level
        local severity_info = map_rails_severity(level, log_severity)
        record["severity_text"] = severity_info.text
        record["severity_number"] = severity_info.number
        
        -- Check if message contains JSON structure
        local json_str = message:match("(%{.+%})")
        if json_str then
            local json_data = parse_json(json_str)
            if json_data then
                attributes["log_type"] = "rails_structured"
                
                -- Extract all JSON fields to attributes
                if json_data.method then attributes["http_method"] = json_data.method end
                if json_data.path then attributes["http_path"] = json_data.path end
                if json_data.format then attributes["http_format"] = json_data.format end
                if json_data.controller then attributes["controller"] = json_data.controller end
                if json_data.action then attributes["action"] = json_data.action end
                if json_data.status then 
                    attributes["http_status"] = tostring(json_data.status)
                    attributes["http_status_code"] = json_data.status
                    
                    -- Update severity based on HTTP status (only for structured logs)
                    if json_data.status >= 500 then
                        record["severity_text"] = "ERROR"
                        record["severity_number"] = 17
                    elseif json_data.status >= 400 then
                        record["severity_text"] = "WARN" 
                        record["severity_number"] = 13
                    else
                        record["severity_text"] = "INFO"
                        record["severity_number"] = 9
                    end
                end
                if json_data.duration then attributes["duration_ms"] = json_data.duration end
                if json_data.view then attributes["view_ms"] = json_data.view end
                if json_data.db then attributes["db_ms"] = json_data.db end
                if json_data.allocations then attributes["allocations"] = json_data.allocations end
                if json_data.request_id then attributes["request_id"] = json_data.request_id end
                if json_data.ip then attributes["client_ip"] = json_data.ip end
                if json_data.user_agent then attributes["user_agent"] = json_data.user_agent end
                if json_data.environment then attributes["rails_env"] = json_data.environment end
                if json_data.severity then attributes["original_severity"] = json_data.severity end
                
                -- Keep original JSON as body for reference
                record["body"] = json_str
            end
        end
        
        -- Check for specific error patterns in Rails logs
        if message:match("ERROR") or message:match("💥") then
            record["severity_text"] = "ERROR"
            record["severity_number"] = 17
            attributes["error_type"] = "application_error"
        elseif message:match("FATAL") or message:match("🔥") then
            record["severity_text"] = "FATAL"
            record["severity_number"] = 21
            attributes["error_type"] = "fatal_error"
        elseif message:match("✅") then
            attributes["success"] = true
        end
        
        -- Extract stack trace if present
        if message:match("RuntimeError") or message:match("Error") then
            attributes["has_stacktrace"] = true
            local error_class = message:match("(%w+Error)")
            if error_class then
                attributes["error_class"] = error_class
            end
            local error_msg = message:match("RuntimeError %(([^)]+)%)")
            if error_msg then
                attributes["error_message"] = error_msg
            end
        end
        
    else
        -- Handle non-Rails format logs (like your "aoco" messages)
        attributes["log_type"] = "application"
        
        -- Check if it's a simple test message
        if log:match("^%w+$") then
            attributes["log_type"] = "test_message"
        end
        
        -- For non-Rails logs, don't use emoji-based severity detection
        -- Keep default INFO unless explicitly indicated otherwise
        record["severity_text"] = "INFO"
        record["severity_number"] = 9
    end
    
    -- Set the attributes in the record
    -- Note: Resource attributes (service.name, host.name, etc.) are set by
    -- content_modifier processor in FluentBit YAML config
    attributes["meta"] = "fluentbit"
    record["attributes"] = attributes

    return 1, ts, record
end

function extract_service_role(tag)
    if tag:match("web") then
        return "web"
    elseif tag:match("scheduler") then
        return "scheduler"
    elseif tag:match("worker") then
        return "worker"
    else
        return "unknown"
    end
end

function map_rails_severity(level, log_severity)
    if level == "F" or log_severity == "FATAL" then
        return {text = "FATAL", number = 21}
    elseif level == "E" or log_severity == "ERROR" then
        return {text = "ERROR", number = 17}
    elseif level == "W" or log_severity == "WARN" then
        return {text = "WARN", number = 13}
    elseif level == "I" or log_severity == "INFO" then
        return {text = "INFO", number = 9}
    else
        return {text = "DEBUG", number = 5}
    end
end

-- Map string level to OTEL severity (for JSON logs with "level" field)
function map_level_to_severity(level)
    if not level then
        return {text = "INFO", number = 9}
    end

    local level_upper = level:upper()

    if level_upper == "FATAL" or level_upper == "CRITICAL" then
        return {text = "FATAL", number = 21}
    elseif level_upper == "ERROR" or level_upper == "ERR" then
        return {text = "ERROR", number = 17}
    elseif level_upper == "WARN" or level_upper == "WARNING" then
        return {text = "WARN", number = 13}
    elseif level_upper == "INFO" then
        return {text = "INFO", number = 9}
    elseif level_upper == "DEBUG" then
        return {text = "DEBUG", number = 5}
    elseif level_upper == "TRACE" then
        return {text = "TRACE", number = 1}
    else
        return {text = "INFO", number = 9}
    end
end

function parse_json(str)
    -- Enhanced JSON parser for Rails logs
    local success, result = pcall(function()
        local json_str = str:match("(%{.+%})")
        if not json_str then
            return nil
        end
        
        -- Handle Rails-style JSON parsing
        json_str = json_str:gsub('([%w_]+):', '"%1":')
        json_str = json_str:gsub(':"([^"]+)"', ':"%1"')
        json_str = json_str:gsub(':([%d%.]+)', ':%1')
        json_str = json_str:gsub(':null', ':nil')
        json_str = json_str:gsub(':true', ':true')
        json_str = json_str:gsub(':false', ':false')
        
        local func_str = "return " .. json_str
        local func = load(func_str)
        if func then
            return func()
        end
        return nil
    end)
    
    if success and type(result) == "table" then
        return result
    end
    
    -- Fallback parser for malformed JSON
    local fallback_result = {}
    
    -- Extract key-value pairs with simpler pattern
    local pattern = '"([^"]+)":([^,}]+)'
    for key, value in str:gmatch(pattern) do
        -- Clean whitespace
        value = value:gsub('^%s+', '')
        value = value:gsub('%s+$', '')
        
        if value == "null" then
            fallback_result[key] = nil
        elseif value == "true" then
            fallback_result[key] = true
        elseif value == "false" then
            fallback_result[key] = false
        elseif value:match('^".*"$') then
            -- Remove quotes
            fallback_result[key] = value:gsub('^"', ''):gsub('"$', '')
        elseif tonumber(value) then
            fallback_result[key] = tonumber(value)
        else
            fallback_result[key] = value
        end
    end
    
    if next(fallback_result) then
        return fallback_result
    end
    
    return nil
end