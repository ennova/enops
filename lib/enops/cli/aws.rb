module Enops::CLI::Aws
  class Command < Enops::CLI::Command
  end

  class MainCommand < Clamp::Command
  end

  Enops::CLI::MainCommand.subcommand 'aws', 'AWS CLI helpers', MainCommand
end
