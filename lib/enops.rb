require 'enops/version'
require 'enops/utils'
require 'enops/heroku'
require 'enops/elastic_beanstalk'
require 'enops/postgresql'

module Enops
  def self.logger=(logger)
    @logger = logger
  end

  def self.logger
    raise 'Enops.logger has not been set' unless @logger
    @logger
  end

  class UserMessageError < StandardError; end
end
