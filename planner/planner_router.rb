require_relative "../tools/tool_guard"
require_relative "../tools/tool_executor"
require_relative "options_buying_planner"
require_relative "../lib/logger"

class PlannerRouter
  def initialize
    @planner = OptionsBuyingPlanner.new
    @logger = AgentLogger.init
  end

  def handle!(tool_call:, account_context:)
    tool = tool_call["name"]
    args = tool_call["arguments"]

    @logger.info("PLANNER: Current step: #{@planner.current_step}")
    @logger.info("PLANNER: Validating tool '#{tool}'")

    ToolGuard.validate!(
      planner: @planner,
      tool: tool,
      payload: args
    )

    @logger.info("PLANNER: Validation passed for '#{tool}'")
    @logger.info("PLANNER: Executing tool '#{tool}'")

    result = ToolExecutor.execute(
      tool: tool,
      payload: args,
      account_context: account_context
    )

    @logger.info("PLANNER: Tool execution completed")
    @logger.info("PLANNER: Advancing from step #{@planner.current_step}")

    @planner.advance!

    @logger.info("PLANNER: Advanced to step: #{@planner.current_step}")

    result
  end
end

