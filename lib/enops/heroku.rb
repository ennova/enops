require 'enops/utils'
require 'fileutils'
require 'heroics'
require 'shellwords'

module Enops
  class Heroku
    HEROKU_ACCEPT = 'application/vnd.heroku+json; version=3'

    attr_reader :username
    attr_reader :password

    def initialize(username, password)
      @username = username
      @password = password

      raise 'Missing Heroku credentials' if password.nil?
    end

    def self.schema_filename
      File.dirname(__FILE__) + '/data/heroku-schema.json'
    end

    def self.schema
      @schema ||= begin
        body = File.read(schema_filename)
        schema = MultiJson.load(body)
        if schema['definitions'].keys == ['schemata']
          schema['definitions'] = schema['definitions']['schemata']
        end
        schema
      end
    end

    def client
      url = "https://#{CGI.escape username}:#{CGI.escape password}@api.heroku.com/"
      @client ||= begin
        schema = Heroics::Schema.new(self.class.schema)
        Heroics.client_from_schema schema, url, default_headers: {'Accept' => HEROKU_ACCEPT}
      end
    end

    def app_names
      with_retry do
        client.app.list.map { |app| app['name'] }
      end
    end

    def get_config_vars(app_name)
      with_retry do
        client.config_var.info_for_app(app_name)
      end
    end

    # Executes any Heroku Toolbelt command
    #   `heroku $ARGS`
    def cmd(app_name, args)
      execute "heroku #{args} --app #{Shellwords.escape app_name}"
    end

    # Run a command on a Heroku dyno
    #   `heroku run $CMD`
    #
    # This wrapper adds support for detecting exit status codes from `heroku run`.
    def run(app_name, cmd)
      exit_status = nil
      execute "heroku run #{Shellwords.escape "(#{cmd}); echo heroku-run-exit-status=$?"} --app #{Shellwords.escape app_name}" do |line|
        if exit_status
          raise "Unexpected output after exit code: #{line.inspect}"
        end
        if line.chomp.chomp =~ /\Aheroku-run-exit-status=(\d+)\z/
          exit_status = Integer($1)
        else
          Enops.logger.debug line.chomp
        end
      end
      raise "#{cmd.inspect} failed with exit status #{exit_status || '<unknown>'}" unless exit_status == 0
    end

    def get_maintenance(app_name)
      info = with_retry do
        client.app.info app_name
      end
      info.fetch('maintenance')
    end

    def set_maintenance(app_name, value)
      info = with_retry do
        client.app.update app_name, maintenance: value
      end
      info.fetch('maintenance')
    end

    def get_ps_scale(app_name)
      formation = with_retry do
        client.formation.list(app_name)
      end
      formation = formation.select { |process| process['quantity'] > 0 }
      Hash[formation.map { |process| process.values_at('type', 'quantity') }]
    end

    def set_ps_scale(app_name, quantities)
      quantities.each do |id, quantity|
        with_retry do
          client.formation.update(app_name, id, quantity: quantity)
        end
      end
    end

    private

    def with_retry
      Enops::Utils.with_retry(caller_label: Enops::Utils.caller_label, tries: 20, sleep: 15, on: Excon::Errors::Error) do
        yield
      end
    end

    def with_heroku_env
      cached_password = password
      Bundler.with_clean_env do
        ENV['HEROKU_API_KEY'] = cached_password
        yield
      end
    ensure
      ENV['HEROKU_API_KEY'] = nil
    end

    def execute(cmd, &block)
      with_heroku_env do
        Enops::Utils.execute(cmd, &block)
      end
    end
  end
end
