module Enops::CLI::Setup
  class MainCommand < Enops::CLI::Command
    def execute
      Enops::CLI::Aws::ConfigureCommand.new(nil).execute
    end
  end

  Enops::CLI::MainCommand.subcommand 'setup', 'Setup Enops environment', MainCommand
end
