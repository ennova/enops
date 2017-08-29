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
      with_retry do
        with_client_headers 'Range' => 'version ..; order=desc, max=1;' do
          client.release.list(app_name).first
        end
      end
    end

    def get_commit_sha(app_name)
      release = get_latest_release(app_name)
      if slug = release.fetch('slug')
        slug = with_retry { client.slug.info(app_name, slug.fetch('id')) }
        slug.fetch('commit')
      end
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

    def postgresql_addon_attachments(app_name)
      with_retry do
        with_client_headers 'Accept-Inclusion' => 'addon:plan,config_vars' do
          client.add_on_attachment.list_by_app(app_name)
            .select { |result| result.fetch('addon').fetch('plan').fetch('name').start_with?('heroku-postgresql:') }
        end
      end
    end

    def postgresql_addon_attachment_production?(attachment)
      plan = attachment.fetch('addon').fetch('plan').fetch('name').split(':')[1]
      !%w[dev basic hobby-dev hobby-basic].include?(plan)
    end

    def postgresql_addon_attachment_detail(attachment)
      addon_id = attachment.fetch('addon').fetch('id')
      hostname = postgresql_addon_attachment_production?(attachment) ? 'postgres-api.heroku.com' : 'postgres-starter-api.heroku.com'

      api_get hostname: hostname, path: "/client/v11/databases/#{addon_id}"
    end

    def postgresql_addon_detail_info(detail)
      detail.fetch('info').map do |row|
        key = row.fetch('name')
        values = row.fetch('values')
        if values.size > 1
          raise KeyError, "key has more than one value: #{key}"
        end

        [key, values.first]
      end.to_h
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
      cached_password = password
      Bundler.with_clean_env do
        ENV['HEROKU_API_KEY'] = cached_password
        yield
      end
    ensure
      ENV['HEROKU_API_KEY'] = nil
    end

    def api_get(hostname:, path:)
      connection = Excon.new(
        'https://' + hostname,
        username: heroku.username,
        password: heroku.password,
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
