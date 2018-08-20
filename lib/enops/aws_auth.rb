require 'aws-sdk-core'
require 'shellwords'

module Enops
  module AwsAuth
    extend self

    def default_credentials
      env_credentials || cli_credentials
    end

    def env_credentials
      if ENV.key?('AWS_ACCESS_KEY_ID')
        Aws::Credentials.new(
          ENV.fetch('AWS_ACCESS_KEY_ID'),
          ENV.fetch('AWS_SECRET_ACCESS_KEY'),
          ENV.fetch('AWS_SESSION_TOKEN', nil),
        )
      end
    end

    def cli_credentials
      Aws::ProcessCredentials.new("#{Shellwords.escape cli_python_bin_path} #{Shellwords.escape cli_credentials_helper_script}").credentials
    end

    def cli_bin_path
      cmd = 'which aws'
      path = `#{cmd}`.strip
      unless $?.success?
        raise Enops::UserMessageError, 'Could not find AWS CLI'
      end
      path
    end

    def cli_python_bin_path
      cli_shebang = shebang = File.open(cli_bin_path, 'r') { |io| io.readline }

      unless shebang =~ /^#!([^ \n]+)/
        raise Enops::UserMessageError, 'Could not extract shebang from AWS CLI'
      end
      interpreter_path = $1

      unless File.basename(interpreter_path).start_with?('python')
        raise Enops::UserMessageError, 'Expected AWS CLI interpreter to be Python'
      end

      interpreter_path
    end

    def cli_credentials_helper_script
      File.dirname(__FILE__) + '/support/aws_cli_get_credentials.py'
    end

    def default_region
      ENV.fetch('AWS_REGION', Aws.shared_config.region)
    end
  end
end
