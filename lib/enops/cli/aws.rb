require 'json'
require 'aws-sdk-core'

module Enops::CLI::Aws
  class Command < Enops::CLI::Command
    private

    def cmd(*args)
      system(*args)
      exit $?.exitstatus unless $?.success?
    end

    def cmd_json(cmd, nil_on_error: false)
      json = `#{cmd}`
      return nil if nil_on_error && !$?.success?
      JSON.parse(json)
    end

    def get_caller_identity(profile_name, nil_on_error: false)
      cmd_json "aws sts get-caller-identity --profile #{Shellwords.escape profile_name}", nil_on_error: nil_on_error
    end

    def extract_identity_username(identity)
      unless identity.fetch('Arn') =~ %r{:user/([\w.-]+)$}
        STDERR.puts "Expected user ARN: #{identity.fetch('Arn')}"
        exit 1
      end
      $1
    end

    def get_account_aliases(profile_name)
      cmd_json("aws iam list-account-aliases --profile #{Shellwords.escape profile_name}").fetch('AccountAliases')
    end

    def get_accounts(profile_name)
      accounts = cmd_json("aws organizations list-accounts --profile #{Shellwords.escape profile_name}").fetch('Accounts')
      accounts.sort_by { |account| account.fetch('JoinedTimestamp') }
    end

    def get_child_accounts(profile_name)
      identity = get_caller_identity(profile_name)
      accounts = get_accounts(profile_name)

      accounts.reject { |account| account.fetch('Id') == identity.fetch('Account') }
    end
  end

  class ConfigureCommand < Command
    option '--force', :flag, 'force reconfiguration of AWS CLI'

    def execute
      ENV.delete 'AWS_PROFILE'
      ensure_aws_cli_installed
      ensure_aws_cli_version
      ensure_aws_master_profile
      ensure_aws_mfa_profile
      ensure_aws_child_profiles
    end

    def ensure_aws_cli_installed
      return if have_command?('aws')

      if have_command?('brew')
        cmd 'brew install awscli'
        return if have_command?('aws')
      end

      STDERR.puts 'AWS CLI is not installed.'
      STDERR.puts
      STDERR.puts 'https://docs.aws.amazon.com/cli/latest/userguide/install-bundle.html'
      exit 1
    end

    def ensure_aws_cli_version
      version = aws_cli_version
      requirement = Gem::Requirement.new('~> 1.12')

      unless requirement.satisfied_by?(version)
        STDERR.puts "AWS CLI #{requirement} is required but have #{version}."
        exit 1
      end
    end

    def ensure_aws_master_profile
      if !have_credentials?('ennova') || force?
        cmd 'aws configure set region ap-southeast-2 --profile ennova'
        cmd 'aws configure --profile ennova'
        STDERR.puts

        unless have_credentials?('ennova')
          STDERR.puts 'AWS credentials not configured.'
          exit 1
        end
      end

      identity = get_caller_identity('ennova', nil_on_error: true)
      unless identity
        STDERR.puts 'Could not authenticate to AWS.'
        STDERR.puts
        STDERR.puts 'Run with --force to reconfigure.'
        exit 1
      end
      username = extract_identity_username(identity)

      aliases = get_account_aliases('ennova')

      puts "Valid credentials for #{username.inspect} on account #{aliases.map(&:inspect).join('+')}."

      unless aliases.include?('ennova-master')
        STDERR.puts
        STDERR.puts 'Expected ennova-master account.'
        STDERR.puts
        STDERR.puts 'Run with --force to reconfigure.'
        exit 1
      end
    end

    def ensure_aws_mfa_profile
      credentials_process_cmd = "#{Shellwords.escape credential_process_path} mfa ennova #{Shellwords.escape mfa_serial_number('ennova')}"
      cmd "aws configure set credential_process #{Shellwords.escape credentials_process_cmd} --profile ennova-mfa"
      cmd 'aws configure set region ap-southeast-2 --profile ennova'
    end

    def ensure_aws_child_profiles
      accounts = get_child_accounts('ennova-mfa')

      if accounts.empty?
        STDERR.puts 'Expected to find at least one child AWS account.'
        exit 1
      end

      accounts.each do |account|
        profile_name = account.fetch('Name').parameterize(separator: '-')
        role_arn = "arn:aws:iam::#{account.fetch('Id')}:role/OrganizationAccountAccessRole"

        credentials_process_cmd = "#{Shellwords.escape credential_process_path} assume-role ennova-mfa #{Shellwords.escape role_arn}"
        cmd "aws configure set credential_process #{Shellwords.escape credentials_process_cmd} --profile #{Shellwords.escape profile_name}"
        cmd "aws configure set region ap-southeast-2 --profile #{Shellwords.escape profile_name}"

        puts "Configured profile: #{profile_name}"
      end
    end

    private

    def aws_cli_version
      result = `aws --version 2>&1`.chomp

      unless $?.success?
        STDERR.puts 'Error retrieving AWS CLI version'
        exit 1
      end

      unless result =~ %r{^aws-cli/([^ ]+) }
        STDERR.puts "Error parsing AWS CLI version: #{result.inspect}"
        exit 1
      end

      Gem::Version.new($1)
    end

    def have_command?(name)
      system("which #{Shellwords.escape name} > /dev/null")
      $?.success?
    end

    def have_credentials?(profile_name)
      Aws.shared_config.fresh
      Aws::SharedCredentials.new(profile_name: profile_name).set?
    rescue Aws::Errors::NoSuchProfileError
      false
    end

    def credential_process_path
      @credential_process_path ||= begin
        bin_dir = File.expand_path('~/.aws/enops/bin')
        FileUtils.mkdir_p bin_dir

        source_path = File.expand_path(File.dirname(__FILE__) + '/../support/aws_cli_credential_process')
        target_path = "#{bin_dir}/aws_cli_credential_process"
        FileUtils.cp source_path, target_path

        target_path
      end
    end

    def get_mfa_devices(profile_name, username)
      if data = cmd_json("aws iam list-mfa-devices --profile #{Shellwords.escape profile_name} --user-name #{Shellwords.escape username}")
        data.fetch('MFADevices')
      end
    end

    def mfa_serial_number(profile_name)
      identity = get_caller_identity(profile_name)
      username = extract_identity_username(identity)
      devices = get_mfa_devices(profile_name, username)
      exit 1 unless devices

      case devices.size
      when 0
        STDERR.puts 'No MFA devices configured.'
        exit 1
      when 1
        devices.first.fetch('SerialNumber')
      else
        STDERR.puts "Expected 1 MFA device but found #{devices.size}."
        exit 1
      end
    end
  end

  class EnvCommand < Command
    def execute
      credentials_env.each do |key, value|
        puts "export #{key}=#{Shellwords.escape value}"
      end
    end

    private

    def credentials
      @credentials ||= Enops::AwsAuth.default_credentials
    end

    def credentials_env
      {
        'AWS_ACCESS_KEY_ID' => credentials.access_key_id,
        'AWS_SECRET_ACCESS_KEY' => credentials.secret_access_key,
        'AWS_SESSION_TOKEN' => credentials.session_token,
      }
    end
  end

  class ExecCommand < EnvCommand
    parameter 'CMD ...', 'application command to run (e.g. "terraform")'

    def cmd
      cmd_list.map(&Shellwords.method(:escape)).join(' ').presence
    end

    def execute
      exec credentials_env, cmd
    end
  end

  class ConsoleCommand < Command
    def execute
      puts "Sign-in:"
      puts "  #{master_signin_url}"
      child_accounts.each do |account|
        puts "#{account.fetch('Name')}:"
        puts "  #{account_switchrole_url(account)}"
      end
    end

    private

    def master_aliases
      @master_aliases ||= get_account_aliases('ennova-mfa')
    end

    def master_signin_url
      "https://#{master_aliases.first}.signin.aws.amazon.com/console"
    end

    def child_accounts
      @child_accounts ||= get_child_accounts('ennova-mfa')
    end

    def account_switchrole_url(account)
      params = {
        displayName: account.fetch('Name'),
        account: account.fetch('Id'),
        roleName: 'OrganizationAccountAccessRole',
        color: account.fetch('Name').end_with?(' Staging') ? 'B7CA9D' : 'F2B0A9',
      }

      "https://signin.aws.amazon.com/switchrole?#{URI.encode_www_form params}"
    end
  end

  class MainCommand < Clamp::Command
    subcommand 'configure', 'configure AWS CLI', ConfigureCommand
    subcommand 'env', 'output AWS CLI credentials', EnvCommand
    subcommand 'exec', 'execute command with AWS CLI credentials', ExecCommand
    subcommand 'console', 'output URLs for the AWS Management Console website', ConsoleCommand
  end

  Enops::CLI::MainCommand.subcommand 'aws', 'AWS CLI helpers', MainCommand
end
