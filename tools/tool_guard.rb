require_relative "../planner/base_planner"
require_relative "../lib/logger"

class ToolGuard
  def self.validate!(planner:, tool:, payload:, allow_intraday_at_o4: false)
    logger = AgentLogger.init

    logger.debug("GUARD: Checking if tool '#{tool}' is allowed at step #{planner.current_step}")

    unless planner.allow_tool?(tool, allow_intraday_at_o4: allow_intraday_at_o4)
      logger.error("GUARD: Tool '#{tool}' NOT allowed at step #{planner.current_step}")
      raise PlannerHalt, "Tool #{tool} not allowed at step #{planner.current_step}"
    end

    logger.debug("GUARD: Tool '#{tool}' is allowed")

    if payload.nil?
      logger.error("GUARD: Empty payload for tool '#{tool}'")
      raise PlannerHalt, "Empty payload for #{tool}"
    end

    logger.debug("GUARD: Payload validation passed for '#{tool}'")
  end
end

