require 'enops/utils'
require 'enops/runner'
require 'fileutils'
require 'netrc'
require 'heroics'
require 'shellwords'
require 'climate_control'
require 'excon'

module Enops
  class Heroku
    HEROKU_ACCEPT = 'application/vnd.heroku+json; version=3'
    HEROKU_POSTGRES_HOBBY_PLANS = %w[dev basic hobby-dev hobby-basic]

    attr_reader :username
    attr_reader :password

    def self.default
      if ENV['HEROKU_API_KEY']
        new('', ENV['HEROKU_API_KEY'])
      else
        username, password = Netrc.read['api.heroku.com']
        new(username, password)
      end
    end

    def initialize(username, password)
      @username = username
      @password = password
      @default_client_headers ||= {'Accept' => HEROKU_ACCEPT}

      raise 'Missing Heroku credentials' if password.nil?
    end

    def self.schema_filename
      File.dirname(__FILE__) + '/data/heroku-schema.json'
    end

    def self.schema
      @schema ||= begin
        body = File.read(schema_filename)
        schema = MultiJson.load(body)
        if schema.fetch('definitions').keys == ['schemata']
          schema['definitions'] = schema.fetch('definitions').fetch('schemata')
        end
        schema
      end
    end

    def client
      url = "https://#{CGI.escape username}:#{CGI.escape password}@api.heroku.com/"
      @client ||= begin
        schema = Heroics::Schema.new(self.class.schema)
        Heroics.client_from_schema schema, url, default_headers: @default_client_headers
      end
    end

    def apps
      with_retry do
        client.app.list
      end
    end

    def app_names
      apps.map { |app| app.fetch('name') }
    end

    def get_config_vars(app_name)
      with_retry do
        client.config_var.info_for_app(app_name)
      end
    end

    def set_config_vars(app_name, config_vars)
      with_retry do
        client.config_var.update app_name, config_vars
      end
    end

    def get_latest_release(app_name)
      get_recent_releases(app_name, 1).first
    end

    def get_recent_releases(app_name, count)
      with_retry do
        with_client_headers 'Range' => "version ..; order=desc, max=#{count};" do
          client.release.list(app_name).first(count)
        end
      end
    end

    def get_last_successful_app_release(app_name)
      is_successful_app_release = lambda do |release|
        is_successful = release.fetch('status') == 'succeeded'
        is_addon = release.fetch('user').fetch('email').end_with?('@addons.heroku.com')

        is_successful && !is_addon
      end

      release = get_latest_release(app_name)
      unless is_successful_app_release[release]
        release = get_recent_releases(app_name, 10).detect(&is_successful_app_release)
        release ||= get_recent_releases(app_name, 50).detect(&is_successful_app_release)
      end

      release
    end

    def get_commit_sha(app_name)
      release = get_last_successful_app_release(app_name)

      commit_sha = nil

      commit_sha ||= if slug = release.fetch('slug')
        slug = with_retry { client.slug.info(app_name, slug.fetch('id')) }
        slug.fetch('commit')
      end

      commit_sha ||= if release.fetch('status') == 'succeeded'
        if url = release.fetch('output_stream_url')
          release_phase_output = Excon.get(url).body
          release_phase_output.match(/^GIT_COMMIT=(.+?)\e\[2K\r/)&.captures&.first
        end
      end

      commit_sha
    end

    def get_collaborators(app_name)
      client.collaborator.list(app_name).map { |collaborator| collaborator.fetch('user').fetch('email') }
    end

    def add_collaborator(app_name, email)
      client.collaborator.create(app_name, user: email)
      true
    rescue Excon::Errors::UnprocessableEntity => e
      response = MultiJson.load(e.response.body)
      raise unless response.fetch('message').include? 'already a collaborator'
      false
    end

    def remove_collaborator(app_name, email)
      client.collaborator.delete(app_name, email)
      true
    rescue Excon::Errors::NotFound
      false
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
      cmd app_name, "run --exit-code #{Shellwords.escape cmd}"
    end

    def run_script!(app_name, script, *script_args)
      runner = Runner.new
      runner.logger = Enops.logger
      runner.raise_on_error = true
      runner.platform = Runner::Platform::Heroku.new(app_name)
      runner.extract_path = '/tmp'
      runner.add_file 'enops-script', 0700, script
      runner.command = ['/tmp/enops-script', *script_args].map(&Shellwords.method(:escape)).join(' ')
      with_heroku_env do
        runner.execute
      end
    end

    def pg_restore!(app_name, backup_url)
      run_script! app_name, File.read(PostgreSQL.pg_restore_script_path), backup_url
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
      format_formation_response(formation)
    end

    def set_ps_scale(app_name, quantities)
      formation = with_retry do
        client.formation.batch_update app_name, {updates: quantities.map { |type, quantity| {type: type, quantity: quantity} }}
      end
      format_formation_response(formation)
    end

    def restart!(app_name)
      with_retry do
        client.dyno.restart_all(app_name)
      end
    end

    def get_feature_enabled(app_name, feature_name)
      result = client.app_feature.info(app_name, feature_name)
      result.fetch('enabled')
    end

    def set_feature_enabled(app_name, feature_name, enabled)
      result = client.app_feature.update app_name, feature_name, enabled: enabled
      new_enabled = result.fetch('enabled')
      unless new_enabled == enabled
        raise "Expected enabled to be #{enabled.inspect} but is #{result.fetch('enabled').inspect}"
      end
      new_enabled
    end

    def data_addon_attachments(app_name, types: %i[postgresql redis])
      plan_pattern = /^heroku-#{Regexp.union(types.map(&:to_s))}:/

      with_retry do
        with_client_headers 'Accept-Inclusion' => 'addon:plan,config_vars' do
          client.add_on_attachment.list_by_app(app_name)
            .select { |result| result.fetch('addon').fetch('plan').fetch('name').match?(plan_pattern) }
        end
      end
    end

    def postgresql_addon_attachments(app_name)
      data_addon_attachments(app_name, types: %i[postgresql])
    end

    def postgresql_addon(addon_name)
      addon = client.add_on.info(addon_name)
      unless addon.fetch('plan').fetch('name').start_with?('heroku-postgresql:')
        raise 'not a PostgreSQL addon'
      end
      addon
    end

    def postgresql_addon_production?(addon)
      plan = addon.fetch('plan').fetch('name').split(':')[1]
      !HEROKU_POSTGRES_HOBBY_PLANS.include?(plan)
    end

    def postgresql_addon_detail(addon, maintenance: false)
      addon_id = addon.fetch('id')
      hostname = postgresql_addon_production?(addon) ? 'postgres-api.heroku.com' : 'postgres-starter-api.heroku.com'

      path = "/client/v11/databases/#{addon_id}"
      path += "/maintenance" if maintenance

      api_get hostname, path
    end

    def redis_addon_detail(addon, maintenance: false)
      path = "/redis/v0/databases/#{addon.fetch("name")}"
      path += "/maintenance" if maintenance
      api_get "redis-api.heroku.com", path
    end

    def data_addon_detail(addon, **args)
      case addon.fetch('plan').fetch('name')
      when /^heroku-postgresql:/
        postgresql_addon_detail(addon, **args)
      when /^heroku-redis:/
        redis_addon_detail(addon, **args)
      else
        raise ArgumentError
      end
    end

    def data_addon_detail_info(detail)
      detail.fetch('info').map do |row|
        key = row.fetch('name')
        values = row.fetch('values')
        if key == 'PG Version' && values.last == '(deprecating)'
          values = values[0..-2]
        end
        if values.size > 1
          raise KeyError, "key has more than one value: #{key}"
        end

        [key, values.first]
      end.to_h
    end
    alias :postgresql_addon_detail_info :data_addon_detail_info

    def postgresql_backups_capture(app_name)
      output = cmd app_name, 'pg:backups:capture'

      unless output =~ /^Backing up [A-Z]+ to (b\d+)\.\.\. done\r?$/
        raise "Could not detect backup ID"
      end
      backup_id = $1

      backup_id
    end

    def postgresql_backups_url(app_name, backup_id)
      output = cmd app_name, "pg:backups:url #{Shellwords.escape backup_id}"

      urls = output.lines.grep(%r{^https://})
      raise "Could not extract backup URL from output" unless urls.size == 1
      urls.first.chomp
    end

    private

    def with_retry
      Enops::Utils.with_retry(caller_label: Enops::Utils.caller_label, tries: 20, sleep: 15, on: Excon::Errors::Error) do
        yield
      end
    end

    def with_client_headers(headers)
      old_headers = @default_client_headers.dup
      @default_client_headers.merge! headers

      yield
    ensure
      @default_client_headers.clear
      @default_client_headers.merge! old_headers
    end

    def with_heroku_env
      Bundler.with_original_env do
        ClimateControl.modify HEROKU_API_KEY: password, CI: 'true' do
          yield
        end
      end
    end

    def api_get(hostname, path)
      connection = Excon.new(
        'https://' + hostname,
        username: username,
        password: password,
        headers: @default_client_headers,
      )

      response = connection.get(
        path: path,
        expects: [200],
      )

      MultiJson.load(response.body)
    end

    def execute(cmd, &block)
      with_heroku_env do
        Enops::Utils.execute(cmd, &block)
      end
    end

    def format_formation_response(formation)
      formation = formation.select { |process| process.fetch('quantity') > 0 }
      Hash[formation.map { |process| [process.fetch('type'), process.fetch('quantity')] }]
    end
  end
end
