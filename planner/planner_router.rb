require_relative "../tools/tool_guard"
require_relative "../tools/tool_executor"
require_relative "options_buying_planner"
require_relative "../lib/logger"

class PlannerRouter
  def initialize
    @planner = OptionsBuyingPlanner.new
    @logger = AgentLogger.init
  end

  def current_step
    @planner.current_step
  end

  def handle!(tool_call:, account_context:, advance: true, allow_intraday_at_o4: false)
    tool = tool_call["name"]
    args = tool_call["arguments"]

    @logger.info("PLANNER: Current step: #{@planner.current_step}")
    @logger.info("PLANNER: Validating tool '#{tool}'")

    ToolGuard.validate!(
      planner: @planner,
      tool: tool,
      payload: args,
      allow_intraday_at_o4: allow_intraday_at_o4
    )

    @logger.info("PLANNER: Validation passed for '#{tool}'")
    @logger.info("PLANNER: Executing tool '#{tool}'")

    result = ToolExecutor.execute(
      tool: tool,
      payload: args,
      account_context: account_context
    )

    @logger.info("PLANNER: Tool execution completed")

    if advance
      @logger.info("PLANNER: Advancing from step #{@planner.current_step}")
      @planner.advance!
      @logger.info("PLANNER: Advanced to step: #{@planner.current_step}")
    else
      @logger.info("PLANNER: Not advancing - staying at step #{@planner.current_step} (more intervals needed)")
    end

    result
  end
end

