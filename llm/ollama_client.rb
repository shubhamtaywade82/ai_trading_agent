require "ollama_client"
require "net/http"
require "json"
require "uri"
require_relative "../lib/logger"

class TradingOllamaClient
  def initialize(model: nil, url: nil)
    @logger = AgentLogger.init

    # Use environment variables or defaults
    @model = model || ENV["OLLAMA_MODEL"] || "nemesis-options-analyst:latest"
    @base_url = url || ENV["OLLAMA_URL"] || "http://localhost:11434"

    @logger.info("OLLAMA: Initializing client")
    @logger.debug("OLLAMA: Model: #{@model}")
    @logger.debug("OLLAMA: URL: #{@base_url}")

    # Validate and parse URL
    raise "Ollama URL cannot be nil or empty" if @base_url.nil? || @base_url.empty?

    # Ensure URL has protocol
    @base_url = "http://#{@base_url}" unless @base_url.start_with?("http://", "https://")

    @url = URI("#{@base_url}/api/chat")
    raise "Invalid Ollama URL: #{@base_url}" unless @url.host

    # Initialize ollama-client gem for configuration and error handling
    config = Ollama::Config.new
    config.model = @model
    config.base_url = @base_url
    config.timeout = 60

    @gem_client = Ollama::Client.new(config: config)
    @logger.info("OLLAMA: Client initialized successfully")
  end

  def chat(messages, tools: nil)
    @logger.info("OLLAMA: Sending chat request")
    @logger.debug("OLLAMA: Messages count: #{messages.length}")
    @logger.debug("OLLAMA: Last message role: #{messages.last[:role]}")
    @logger.debug("OLLAMA: Tools provided: #{tools ? tools.length : 0}")

    # Use Ollama's chat API for tool calling support
    # The ollama-client gem focuses on structured output via generate(),
    # but we need the chat API for tool_calls support
    payload = {
      model: @model,
      messages: messages,
      stream: false
    }

    # Add tools if provided (Ollama supports tool calling)
    payload[:tools] = tools if tools && !tools.empty?

    begin
      # Validate URL before making request
      raise "Invalid URL: host is nil. Check OLLAMA_URL environment variable." if @url.host.nil?

      @logger.debug("OLLAMA: Connecting to #{@url.host}:#{@url.port}")

      http = Net::HTTP.new(@url.host, @url.port)
      http.read_timeout = 60
      http.open_timeout = 10

      request = Net::HTTP::Post.new(@url.path)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      @logger.debug("OLLAMA: Sending POST request to #{@url.path}")

      response = http.request(request)

      @logger.info("OLLAMA: Received response (status: #{response.code})")

      unless response.is_a?(Net::HTTPSuccess)
        case response.code.to_i
        when 404
          raise "Model '#{@model}' not found at #{@base_url}"
        else
          raise "Ollama API error: HTTP #{response.code} - #{response.message}"
        end
      end

      body = JSON.parse(response.body)

      @logger.debug("OLLAMA: Raw response body keys: #{body.keys.inspect}")

      msg = body["message"] || body

      @logger.debug("OLLAMA: Message keys: #{msg.keys.inspect if msg.is_a?(Hash)}")
      @logger.debug("OLLAMA: Full message: #{msg.inspect}")

      # Parse tool calls - Ollama may return them in different formats
      tool_calls = msg["tool_calls"] || msg[:tool_calls] || []

      @logger.debug("OLLAMA: Raw tool_calls: #{tool_calls.inspect}")

      # Normalize tool calls format
      normalized_tool_calls = tool_calls.map do |tc|
        if tc.is_a?(Hash)
          # Handle different possible formats
          tool_call = {
            "name" => tc["function"]&.dig("name") || tc["name"] || tc[:name] || tc["function_name"] || "",
            "arguments" => parse_tool_arguments(tc)
          }

          @logger.debug("OLLAMA: Parsed tool call - Name: '#{tool_call['name']}', Args: #{tool_call['arguments'].inspect}")

          if tool_call["name"].empty?
            @logger.warn("OLLAMA: WARNING - Tool call has empty name! Raw: #{tc.inspect}")
          end

          tool_call
        else
          @logger.warn("OLLAMA: Unexpected tool call format: #{tc.inspect}")
          { "name" => "", "arguments" => {} }
        end
      end

      tool_calls_count = normalized_tool_calls.length
      content_length = (msg["content"] || msg["message"] || "").length

      @logger.info("OLLAMA: Response parsed - Content: #{content_length} chars, Tool calls: #{tool_calls_count}")

      result = {
        content: msg["content"] || msg["message"] || "",
        tool_calls: normalized_tool_calls
      }

      if tool_calls_count > 0
        tool_names = normalized_tool_calls.map { |tc| tc["name"] }.reject(&:empty?)
        @logger.debug("OLLAMA: Tool calls: #{tool_names.join(", ")}")
      end

      result
    rescue Errno::ECONNREFUSED => e
      raise "Cannot connect to Ollama at #{@base_url}. Is Ollama running? Error: #{e.message}"
    rescue Timeout::Error, Net::ReadTimeout, Net::OpenTimeout => e
      raise "Request timed out: #{e.message}"
    rescue JSON::ParserError => e
      raise "Invalid JSON response: #{e.message}"
    rescue => e
      raise "Ollama connection error: #{e.class} - #{e.message}. URL: #{@base_url}, Host: #{@url.host.inspect}"
    end
  end

  private

  def parse_tool_arguments(tool_call)
    # Handle different argument formats from Ollama
    args = tool_call["function"]&.dig("arguments") ||
           tool_call["arguments"] ||
           tool_call[:arguments] ||
           tool_call["function_arguments"] ||
           {}

    # If arguments is a string (JSON), parse it
    if args.is_a?(String)
      begin
        args = JSON.parse(args)
      rescue JSON::ParserError
        @logger.warn("OLLAMA: Failed to parse tool arguments JSON: #{args}")
        args = {}
      end
    end

    args
  end
end

