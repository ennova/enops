require 'tty-table'
require 'active_support/inflector'

STDOUT.sync = true

module Enops::CLI::ElasticBeanstalk
  module ErrorHandling
    def execute
      super
    rescue Enops::ExecuteError, Aws::Errors::ServiceError => e
      $stderr.puts "#{e.message}"
      exit 1
    end
  end

  class Command < Clamp::Command
    def self.inherited(subclass)
      subclass.class_eval do
        prepend ErrorHandling
      end
    end

    private

    def api
      @api ||= Enops::ElasticBeanstalk.new
    end

    def table(header: nil, rows:, key_labels: nil)
      if header.nil?
        keys = rows.map(&:keys).inject(:|)
        header = keys.map { |key| key_labels&.fetch(key, nil) || key.to_s.titleize }
        rows = rows.map { |row| row.values_at(*keys) }
      else
        raise ArgumentError if key_labels
      end

      table = TTY::Table.new header: header, rows: rows
      puts table.render(width: 1e9) { |renderer|
        renderer.border do
          mid '='
          mid_mid '  '
          center '  '
        end
      }
    end
  end

  class AppCommand < Command
    option '--app', 'NAME', 'application to run command against', attribute_name: :app_name, required: true, environment_variable: 'ENOPS_APP_NAME'

    def output_events(events)
      events.each do |event|
        puts "#{event.event_date.localtime} #{event.environment_name} #{event.severity} #{event.message}"
      end
    end

    def status_complete?(status)
      status.all? { |env_type, env_status| env_status.fetch(:complete) }
    end

    def waitable
      api_cached = api.cached
      events_response = api_cached.get_events(app_name: app_name)
      last_status = block_given? ? api_cached.get_status(app_name) : nil
      last_activity = Time.now

      yield if block_given?

      begin
        events_response = api.get_events(app_name: app_name, next_token: events_response&.next_token)
        status = api.get_status(app_name)

        status.each do |env_type, env_status|
          should_output_status = if last_status
            status.fetch(env_type) != last_status.fetch(env_type)
          else
            !env_status.fetch(:complete)
          end

          if should_output_status
            puts <<-EOF.squish
              #{Time.now} #{app_name}-#{env_type}
              STATUS #{env_status.fetch(:status)}
              (health: #{env_status.fetch(:health_status)} (#{env_status.fetch(:health)}))
            EOF
            last_activity = Time.now
          end
        end
        last_status = status

        output_events events_response.events
        last_activity = Time.now if !events_response.events.empty?

        sleep 2
        expired = Time.now > last_activity + 300
      end until status_complete?(status) || expired

      if expired
        $stderr.puts "#{Time.now} Timed out waiting for completion."
        exit 1
      end
    end
  end

  class ListCommand < Command
    option '--json', :flag, 'format output as JSON'

    def execute
      data = api.app_versions

      if json?
        puts JSON.dump(data)
      else
        table header: ['Application Name', 'Version Label'], rows: data.to_a
      end
    end
  end

  class StatusCommand < AppCommand
    def execute
      env_statuses = api.get_status(app_name)
      rows = env_statuses.map { |env_type, status| {env_type: env_type}.merge(status) }
      table rows: rows, key_labels: {env_type: 'Environment'}
    end
  end

  class EventsCommand < AppCommand
    def execute
      response = api.get_events(app_name: app_name)
      output_events response.events
    end
  end

  class WaitCommand < AppCommand
    def execute
      waitable
    end
  end

  class GetScaleCommand < AppCommand
    option '--json', :flag, 'format output as JSON'
    option '--[no-]current', :flag, 'include current instance counts (default unless JSON mode)'

    def execute
      cached_api = api.cached
      data = cached_api.get_scaling(app_name).dup
      if current?.nil? ? !json? : current?
        cached_api.get_instances(app_name).each do |env_type, instances|
          data[env_type][:current] = instances.size
        end
      end

      if json?
        puts JSON.pretty_generate(data)
      else
        rows = data.map { |env_type, row| {env_type: env_type}.merge(row) }
        table rows: rows, key_labels: {env_type: 'Environment', type: 'Instance Type'}
      end
    end
  end

  class SetScaleCommand < AppCommand
    option '--json', :flag, 'read JSON from stdin'

    parameter '[SCALE] ...', 'scale settings (e.g. web=1-4:t2.micro worker=2)'

    def scaling
      if json?
        unless scale_list.empty?
          signal_usage_error 'cannot combine both JSON input and scale parameters'
        end
        JSON.parse(STDIN.read)
      else
        if scale_list.empty?
          signal_usage_error 'no scaling settings provided'
        end
        scale_list.map do |scale|
          match = /^(?<env_type>[a-z]+)=((?<min>\d+)-)?(?<max>\d+)(:(?<type>[a-z0-9.]+))?$/.match(scale)
          signal_usage_error "Invalid scale setting: #{scale.inspect}" unless match
          scale = match.named_captures

          scale['min'] ||= scale.fetch('max')
          scale.delete 'type' if scale.fetch('type').nil?
          env_type = scale.delete('env_type')

          [env_type, scale]
        end.to_h
      end
    end

    def execute
      waitable do
        api.set_scaling app_name, scaling
      end
    end
  end

  class RestartCommand < AppCommand
    def execute
      waitable do
        api.restart_app_server app_name
      end
    end
  end

  class GetConfigCommand < AppCommand
    option '--json', :flag, 'format output as JSON'
    parameter '[KEY]', 'retrieve single environment variable'

    def execute
      data = api.get_config_vars(app_name)

      if key
        data = data.fetch(key, nil)
        if json?
          puts JSON.dump(data)
        else
          if data.is_a? Hash
            $stderr.puts "Error: #{app_name} environments have conflicting values for #{key.inspect}."
            exit 1
          end
          puts data
        end
      else
        if json?
          puts JSON.pretty_generate(data)
        else
          data.each do |key, value|
            if value.is_a? Hash
              value.each do |env_type, env_value|
                if env_value
                  puts "#{Shellwords.escape key}:#{Shellwords.escape env_type}=#{Shellwords.escape env_value}"
                end
              end
            else
              puts "#{Shellwords.escape key}=#{Shellwords.escape value}"
            end
          end
        end
      end
    end
  end

  class SetConfigCommand < AppCommand
    option '--json', :flag, 'read JSON from stdin'

    parameter '[CONFIG] ...', 'environment configuration (e.g. FOO=bar)'

    def config_vars
      if json?
        unless config_list.empty?
          signal_usage_error 'cannot combine both JSON input and environment config parameters'
        end
        JSON.parse(STDIN.read)
      else
        if config_list.empty?
          signal_usage_error 'no environment config provided'
        end
        config_vars = {}
        config_list.each do |config_var|
          match = /^(?<key>[A-Z0-9_]+)(:(?<env_type>[a-z]+))?=(?<value>.+)?$/.match(config_var)
          signal_usage_error "Invalid environment config parameter: #{config_var.inspect}" unless match
          config_var = match.named_captures

          if config_var.fetch('env_type').nil?
            config_vars[config_var.fetch('key')] = config_var.fetch('value')
          else
            values = config_vars[config_var.fetch('key')] ||= {}
            values[config_var.fetch('env_type')] = config_var.fetch('value')
          end
        end
        config_vars
      end
    end

    def execute
      waitable do
        api.set_config_vars app_name, config_vars
      end
    end
  end

  class RunPostgresCommand < AppCommand
    parameter '[CMD] ...', 'PostgreSQL command to run', default: %w[psql]

    def execute
      api.run_pg_cmd! app_name, cmd_list.map(&Shellwords.method(:escape)).join(' ')
    end
  end

  class RunAppCommand < AppCommand
    parameter 'CMD ...', 'application command to run (e.g. "console")'

    def execute
      api.run_app_cmd! app_name, cmd_list.map(&Shellwords.method(:escape)).join(' ')
    end
  end

  class RunInstanceSSHCommand < AppCommand
    parameter '[CMD] ...', 'command to run'
    option '--env-type', 'ENV_TYPE', 'environment to select EC2 instance from', default: 'web'

    def execute
      api.run_instance_ssh! app_name, env_type: env_type, cmd: cmd_list.map(&Shellwords.method(:escape)).join(' ').presence
    end
  end

  class TailAppLogCommand < AppCommand
    def execute
      api.tail_app_log! app_name
    end
  end

  class AvailableVersionsCommand < Command
    option '--json', :flag, 'format output as JSON'
    option '--[no-]exclude-ref-only', :flag, 'exclude versions without any non-ref labels', default: true

    def execute
      versions = api.available_versions.reverse

      if exclude_ref_only?
        versions = versions.reject do |version|
          version.fetch(:version_labels).all? do |version_label|
            version_label.start_with?('ref-')
          end
        end
      end

      if json?
        puts JSON.pretty_generate(versions)
      else
        rows = versions.map do |version|
          {
            version_labels: version.fetch(:version_labels).join(', '),
            created_at: version.fetch(:created_at),
          }
        end
        table rows: rows
      end
    end
  end

  class DeployCommand < AppCommand
    option '--force-version', :flag, 'force deployment of non-ref (ref-*) or release (v*) version label'

    parameter 'VERSION_LABEL', 'version of application to deploy'

    def execute
      unless version_label =~ /^ref-|^v\d/
        if !force_version?
          signal_usage_error "#{version_label} does not look like a ref or release label. Use --force-version if you are sure."
        end
      end

      waitable do
        api.start_deploy app_name, version_label
      end
    end
  end

  class MainCommand < Clamp::Command
    subcommand 'apps', 'list all application names', ListCommand
    subcommand 'status', 'show high-level application status', StatusCommand
    subcommand 'events', 'show recent Elastic Beanstalk events', EventsCommand
    subcommand 'wait', 'wait for application status to be ready', WaitCommand
    subcommand 'scale', 'show current EC2 instance type and scaling range', GetScaleCommand
    subcommand 'scale:set', 'set EC2 instance type and scaling range', SetScaleCommand
    subcommand 'restart', 'restart application processes', RestartCommand
    subcommand 'config', 'show current configuration environment variables', GetConfigCommand
    subcommand 'config:set', 'update configuration environment variables', SetConfigCommand
    subcommand 'pg', 'run PostgreSQL command (e.g. psql)', RunPostgresCommand
    subcommand 'run', 'run application command (e.g. console)', RunAppCommand
    subcommand 'ssh', 'SSH to an application EC2 instance (for debugging)', RunInstanceSSHCommand
    subcommand 'tail', 'tail the application log', TailAppLogCommand
    subcommand 'versions', 'list available application versions', AvailableVersionsCommand
    subcommand 'deploy', 'deploy an application version', DeployCommand
  end

  Enops::CLI::MainCommand.subcommand 'eb', 'Elastic Beanstalk', MainCommand
end
