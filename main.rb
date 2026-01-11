require "bundler/setup"
require "dotenv/load"
require_relative "lib/logger"
require_relative "llm/ollama_client"
require_relative "agent/trading_agent"
require_relative "planner/planner_router"
require_relative "dhan/client"

logger = AgentLogger.init
logger.info("=" * 60)
logger.info("MAIN: Starting AI Trading Agent")
logger.info("=" * 60)

# Load environment variables from .env file
# DhanClient uses DhanHQ.configure_with_env which reads from ENV
# Required: CLIENT_ID and ACCESS_TOKEN
# Optional: DHAN_LOG_LEVEL, DHAN_BASE_URL, etc.
logger.info("MAIN: Initializing DhanHQ client")
begin
  dhan_client = DhanClient.new
  logger.info("MAIN: DhanHQ client initialized successfully")
rescue => e
  logger.error("MAIN: Error initializing DhanHQ client: #{e.message}")
  logger.error("MAIN: Make sure CLIENT_ID and ACCESS_TOKEN are set in .env file")
  puts "Error initializing DhanHQ client: #{e.message}"
  puts "Make sure CLIENT_ID and ACCESS_TOKEN are set in .env file"
  exit 1
end

# TradingOllamaClient reads model from ENV["OLLAMA_MODEL"] or defaults to "nemesis-options-analyst:latest"
# You can also pass model and url directly: TradingOllamaClient.new(model: "llama3.1:8b", url: "http://localhost:11434")
logger.info("MAIN: Initializing Ollama client")
llm = TradingOllamaClient.new
logger.info("MAIN: Ollama client initialized successfully")

logger.info("MAIN: Initializing planner")
planner = PlannerRouter.new
logger.info("MAIN: Planner initialized successfully")

logger.info("MAIN: Creating trading agent")
agent = TradingAgent.new(
  llm: llm,
  planner_router: planner
)
logger.info("MAIN: Trading agent created")

user_query = "Can I buy NIFTY CE today?"
logger.info("MAIN: Starting agent execution")
logger.info("MAIN: User query: #{user_query}")

result = agent.run(
  user_query: user_query,
  account_context: {
    capital: 500_000,
    max_risk_per_trade: 0.5,
    dhan_client: dhan_client
  }
)

logger.info("=" * 60)
logger.info("MAIN: Agent execution completed")
logger.info("=" * 60)
puts "\n" + "=" * 60
puts "FINAL OUTPUT:"
puts "=" * 60
puts result
puts "=" * 60

