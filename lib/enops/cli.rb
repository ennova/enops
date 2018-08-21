require 'clamp'

module Enops
  module CLI
    class MainCommand < Clamp::Command
    end
  end
end

Clamp.allow_options_after_parameters = true

require 'enops/cli/elastic_beanstalk'
