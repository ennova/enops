require 'fileutils'
require 'heroics'
require 'pty'
require 'retryable'
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

    def self.schema
      @schema ||= begin
        if File.exists?('tmp/schema.json')
          body = File.read('tmp/schema.json')
        else
          body = Excon.get('https://api.heroku.com/schema', headers: {'Accept' => HEROKU_ACCEPT}, expects: [200]).body
          FileUtils.mkdir_p 'tmp'
          File.write 'tmp/schema.json', body
        end

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
        client.config_var.info(app_name)
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
      caller_label = caller[0][/`([^']*)'$/, 1]
      max_tries = 20

      Retryable.retryable(tries: max_tries, sleep: 15, on: Excon::Errors::Error) do |try_num|
        Enops.logger.warn "Retrying #{caller_label} (try #{try_num+1} of #{max_tries})" if try_num > 0
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

    def execute(cmd)
      with_heroku_env do
        PTY.spawn "(#{cmd}) 2>&1" do |r, w, pid|
          begin
            loop do
              line = r.readline
              if block_given?
                yield line
              else
                Enops.logger.debug line.chomp
              end
            end
          rescue EOFError, Errno::EIO
          end
          status = PTY.check(pid)
          raise "#{cmd.inspect} failed with exit status #{status.exitstatus}" unless status.success?
        end
      end
    end
  end
end
