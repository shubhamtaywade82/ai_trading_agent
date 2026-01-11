require "logger"

class AgentLogger
  @@logger = nil

  def self.init
    @@logger ||= Logger.new(STDOUT)
    @@logger.level = Logger::DEBUG
    @@logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime.strftime('%H:%M:%S')}] #{severity} -- #{msg}\n"
    end
    @@logger
  end

  def self.logger
    @@logger || init
  end

  def self.debug(msg)
    logger.debug(msg)
  end

  def self.info(msg)
    logger.info(msg)
  end

  def self.warn(msg)
    logger.warn(msg)
  end

  def self.error(msg)
    logger.error(msg)
  end
end

