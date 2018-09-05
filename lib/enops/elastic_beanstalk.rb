require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/hash/reverse_merge'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/module/delegation'
require 'active_support/core_ext/string/filters'
require 'active_support/core_ext/string/strip'
require 'enops/aws_auth'
require 'aws-sdk-elasticbeanstalk'
require 'aws-sdk-ec2'
require 'aws-sdk-ecr'
require 'aws-sdk-s3'
require 'net/ssh/gateway'
require 'climate_control'
require 'zip'

module Enops
  class ElasticBeanstalk
    APPLICATION_NAME = 'envision'
    CONFIG_VAR_NAMESPACE = 'aws:elasticbeanstalk:application:environment'
    AUTOSCALING_LAUNCH_NAMESPACE = 'aws:autoscaling:launchconfiguration'
    AUTOSCALING_GROUP_NAMESPACE = 'aws:autoscaling:asg'

    def initialize(region: nil, credentials: nil, cached: false)
      @region = region
      @credentials = credentials
      @cache = cached ? {} : nil
    end

    def cached
      self.class.new(
        region: region,
        credentials: credentials,
        cached: true,
      )
    end

    def cached?
      !@cache.nil?
    end

    def app_names
      app_environments.keys
    end

    def app_versions
      app_environments.transform_values do |app_envs|
        version_labels = app_envs.values.map(&:version_label).uniq
        if version_labels.size == 1
          version_labels.first
        end
      end
    end

    def get_status(app_name)
      app_environments.fetch(app_name).map do |env_type, environment|
        complete =
          environment.status == 'Ready' &&
          environment.health == 'Green' &&
          environment.health_status == 'Ok' &&
          !environment.abortable_operation_in_progress

        data = {
          status: environment.status,
          health: environment.health,
          health_status: environment.health_status,
          version_label: environment.version_label,
          complete: complete,
          abortable_operation_in_progress: environment.abortable_operation_in_progress,
        }
        [env_type, data]
      end.to_h
    end

    GetEventsResponse = Struct.new(:events, :next_token)

    def get_events(app_name: nil, start_time: nil, next_token: nil)
      environment_names = if next_token
        next_token.keys
      else
        raise ArgumentError, 'missing keyword: app_name' unless app_name
        app_environments.fetch(app_name).values.map(&:environment_name)
      end

      events = []

      environment_names.each do |environment_name|
        if start_time || next_token
          events += eb_client.describe_events(
            environment_name: environment_name,
            start_time: start_time || next_token.fetch(environment_name),
          ).events
        else
          events += eb_client.describe_events(
            environment_name: environment_name,
            start_time: Time.now.utc - 60,
            max_records: 100,
          ).events
          events += eb_client.describe_events(
            environment_name: environment_name,
            start_time: nil,
            max_records: 10,
          ).events
        end
      end

      events_by_index = events.uniq.each_with_index.to_h
      events = events.sort_by do |event|
        [
          event.event_date,
          -events_by_index.fetch(event),
        ]
      end

      new_next_token = {}

      if start_time
        environment_names.each do |environment_name|
          new_next_token[environment_name] = start_time
        end
      end

      if next_token
        next_token.each do |environment_name, start_time|
          new_next_token[environment_name] = [new_next_token[environment_name], start_time].compact.max
        end
      end

      events.each do |event|
        new_next_token[event.environment_name] = [new_next_token[event.environment_name], event.event_date + 1].compact.max
      end

      GetEventsResponse.new(events, new_next_token)
    end

    def get_config_vars(app_name)
      env_config_vars = app_environments.fetch(app_name)
        .map { |env_type, environment| [env_type, get_environment_config_vars(environment.environment_name)] }
        .to_h

      keys = env_config_vars.values.flat_map(&:keys).uniq.sort

      keys.map do |key|
        values = env_config_vars
          .map { |env_type, vars| [env_type, vars.fetch(key, nil)] }
          .to_h
        value = values.values.uniq.size == 1 ? values.values.first : values

        [key, value]
      end.to_h
    end

    def set_config_vars(app_name, config_vars)
      envs = app_environments.fetch(app_name).map do |env_type, environment|
        [env_type, environment.environment_name]
      end.to_h

      env_type_updates = {}

      config_vars.each do |key, values|
        unless values.is_a?(Hash)
          values = envs.keys.map { |env_type| [env_type, values] }.to_h
        end

        values.each do |env_type, value|
          environment_name = envs.fetch(env_type) do
            raise UserMessageError, "Unknown environment type: #{env_type.inspect}"
          end

          env_type_updates[env_type] ||= {
            environment_name: environment_name,
          }

          unless value.nil?
            env_type_updates[env_type][:option_settings] ||= []
            env_type_updates[env_type][:option_settings] << Aws::ElasticBeanstalk::Types::ConfigurationOptionSetting.new(
              namespace: CONFIG_VAR_NAMESPACE,
              option_name: key,
              value: value,
            )
          else
            env_type_updates[env_type][:options_to_remove] ||= []
            env_type_updates[env_type][:options_to_remove] << Aws::ElasticBeanstalk::Types::OptionSpecification.new(
              namespace: CONFIG_VAR_NAMESPACE,
              option_name: key,
            )
          end
        end
      end

      env_type_updates.values.each do |update|
        eb_client.update_environment(update)
      end

      nil
    end

    def get_scaling(app_name)
      app_environments.fetch(app_name).map do |env_type, environment|
        settings = get_environment_settings(environment.environment_name)
        autoscaling_launch_settings = settings
          .select { |setting| setting.namespace == AUTOSCALING_LAUNCH_NAMESPACE }
          .map { |setting| [setting.option_name, setting.value] }
          .to_h
        autoscaling_group_settings = settings
          .select { |setting| setting.namespace == AUTOSCALING_GROUP_NAMESPACE }
          .map { |setting| [setting.option_name, setting.value] }
          .to_h

        result = {
          type: autoscaling_launch_settings.fetch('InstanceType'),
          min: Integer(autoscaling_group_settings.fetch('MinSize')),
          max: Integer(autoscaling_group_settings.fetch('MaxSize')),
        }

        [env_type, result]
      end.to_h
    end

    def set_scaling(app_name, scaling)
      envs = app_environments.fetch(app_name).map do |env_type, environment|
        [env_type, environment.environment_name]
      end.to_h

      env_type_updates = {}

      scaling.each do |env_type, values|
        environment_name = envs.fetch(env_type) do
          raise UserMessageError, "Unknown environment type: #{env_type.inspect}"
        end

        env_type_updates[env_type] ||= {
          environment_name: environment_name,
        }

        values.each do |key, value|
          namespace, name = case key.to_s
          when 'min'
            [AUTOSCALING_GROUP_NAMESPACE, 'MinSize']
          when 'max'
            [AUTOSCALING_GROUP_NAMESPACE, 'MaxSize']
          when 'type'
            [AUTOSCALING_LAUNCH_NAMESPACE, 'InstanceType']
          else
            raise UserMessageError, "Unknown scaling option: #{key}"
          end

          env_type_updates[env_type][:option_settings] ||= []
          env_type_updates[env_type][:option_settings] << Aws::ElasticBeanstalk::Types::ConfigurationOptionSetting.new(
            namespace: namespace,
            option_name: name,
            value: value.to_s,
          )
        end
      end

      env_type_updates.values.each do |update|
        eb_client.update_environment(update)
      end

      nil
    end

    def get_instances(app_name)
      app_environments.fetch(app_name).map do |env_type, environment|
        instances = eb_client.describe_environment_resources(environment_name: environment.environment_name)
          .flat_map(&:environment_resources).flat_map(&:instances)
        [env_type, instances.map(&:id)]
      end.to_h
    end


    def restart_app_server(app_name)
      app_environments.fetch(app_name).values.each do |environment|
        eb_client.restart_app_server(environment_name: environment.environment_name)
      end

      nil
    end

    def run_pg_cmd!(app_name, cmd)
      with_pg_env app_name do
        system cmd
        unless $?.success?
          raise ExecuteError.new(cmd: cmd, status: $?, output: nil)
        end
      end
    end

    def run_app_cmd!(app_name, cmd)
      instances = get_instances(app_name)
      instance_id = instances.fetch('worker', []).sample || instances.values.flatten.sample

      system instance_docker_run_cmd(instance_id, cmd)
      unless $?.success?
        raise ExecuteError.new(cmd: cmd, status: $?, output: nil)
      end
    end

    def pg_restore!(app_name, backup_url)
      run_app_cmd! app_name, <<-SH.strip_heredoc.strip
        wget -O /tmp/backup.dump #{Shellwords.escape backup_url}
        pg_restore -l /tmp/backup.dump | grep -v 'COMMENT - EXTENSION' > /tmp/backup.list
        PGUSER="$(echo "${DATABASE_URL?}" | ruby -ruri -e 'puts URI.parse(STDIN.read.chomp).user')"
        echo Resetting...
        PGOPTIONS='--client-min-messages=warning' psql -X -q -v ON_ERROR_STOP=1 "${DATABASE_URL?}" -c "DROP OWNED BY ${PGUSER?} CASCADE; CREATE SCHEMA public;"
        echo Restoring...
        pg_restore --jobs=4 --no-acl --no-owner --dbname "${DATABASE_URL?}" --exit-on-error -L /tmp/backup.list /tmp/backup.dump
        echo Done.
        rm /tmp/backup.list /tmp/backup.dump
      SH
    end

    def run_instance_ssh!(app_name, env_type:, cmd: nil)
      instance_id = get_instances(app_name).fetch(env_type).sample
      system "#{instance_ssh_cmd(instance_id)} #{Shellwords.escape cmd}"
    end

    def tail_app_log!(app_name)
      instance_ids = get_instances(app_name).values.flatten
      run_on_instances! instance_ids, docker_log_tail_cmd
    end

    def available_versions
      image_details = ecr_client.describe_images(
        repository_name: APPLICATION_NAME,
      ).image_details

      image_details.map do |image_detail|
        {
          version_labels: Array(image_detail.image_tags),
          created_at: image_detail.image_pushed_at,
        }
      end
    end

    def start_deploy(app_name, version_label, env_types: nil)
      create_app_version version_label

      environments = app_environments.fetch(app_name)
      env_types ||= environments.keys
      environments = env_types.flat_map { |env_type| environments.fetch(env_type) }

      environments.map do |environment|
        eb_client.update_environment(
          environment_name: environment.environment_name,
          version_label: version_label,
        )
      end
    end

    private

    def region
      @region ||= Enops::AwsAuth.default_region
    end

    def credentials
      @credentials ||= Enops::AwsAuth.default_credentials
    end

    def client_options
      {
        region: region,
        credentials: credentials,
      }
    end

    def eb_client
      @eb_client ||= Aws::ElasticBeanstalk::Client.new(client_options)
    end

    def ec2_client
      @ec2_client ||= Aws::EC2::Client.new(client_options)
    end

    def ecr_client
      @ecr_client ||= Aws::ECR::Client.new(client_options)
    end

    def s3_client
      @s3_client ||= Aws::S3::Client.new(client_options)
    end

    def cacheable(key)
      if @cache
        @cache.fetch(key) do
          @cache[key] = yield
        end
      else
        yield
      end
    end

    def environments
      cacheable "environments" do
        eb_client.describe_environments.flat_map(&:environments).index_by(&:environment_name)
      end
    end

    class AppEnvironments
      def initialize
        @data ||= {}
      end

      delegate :keys, :transform_values, to: :@data

      def fetch(app_name)
        @data.fetch(app_name) do
          raise UserMessageError, "Unknown application name: #{app_name.inspect}"
        end
      end

      def add(app_name:, env_type:, environment:)
        @data[app_name] ||= {
          'web' => nil,
          'worker' => nil,
        }
        @data[app_name][env_type] = environment
      end
    end

    def app_environments
      begin
        result = AppEnvironments.new
        environments.values.each do |environment|
          match = /^(?<app_name>e7(?:stg)?-.+?)-(?<env_type>[^-]+(?:-\d+)?)$/.match(environment.environment_name)
          raise "Could not parse #{environment.environment_name.inspect}" unless match
          app_name = match.named_captures.fetch('app_name')
          env_type = match.named_captures.fetch('env_type')

          result.add app_name: app_name, env_type: env_type, environment: environment
        end
        result
      end
    end

    def get_environment_settings(environment_name)
      cacheable "get_environment_settings:#{environment_name}" do
        eb_client.describe_configuration_settings(
          application_name: APPLICATION_NAME,
          environment_name: environment_name
        ).configuration_settings.first.option_settings
      end
    end

    def get_environment_config_vars(environment_name)
      result = {}
      get_environment_settings(environment_name).each do |setting|
        next unless setting.namespace == CONFIG_VAR_NAMESPACE
        raise unless setting.resource_name.nil?
        raise if result.key?(setting.option_name)
        result[setting.option_name] = setting.value
      end
      result
    end

    def find_instance(filter)
      instances = ec2_client.describe_instances(
        filters: filter.map do |name, values|
          {
            name: name,
            values: Array(values),
          }
        end,
      ).flat_map(&:reservations).flat_map(&:instances)
      unless instances.size == 1
        raise "Expect to find 1 instance matching #{filter.inspect} but found #{instances.size}"
      end
      instances.first
    end

    def bastion_instance
      @bastion_instance ||= begin
        instance = find_instance(
          'instance.group-name' => 'bastion'
        )
        if instance.public_dns_name.blank?
          raise "Expected bastion host #{instance.instance_id} to have a public DNS name"
        end
        instance
      end
    end

    def generate_ec2_key_fingerprint(path)
      cmd = "openssl pkcs8 -in #{Shellwords.escape(path)} -inform PEM -outform DER -topk8 -nocrypt 2> /dev/null"
      data = Kernel.open("|#{cmd}", 'r:binary') { |io| io.read }
      digest = Digest::SHA1.hexdigest(data)
      digest.gsub(/..(?=.)/, '\0:')
    end

    def identity_path(key_name)
      key_fingerprint = ec2_client.describe_key_pairs(
        filters: [{name: 'key-name', values: [key_name]}]
      ).key_pairs.first&.key_fingerprint

      unless key_fingerprint
        raise UserMessageError, "Could not find key pair fingerprint for #{key_name.inspect}"
      end

      path = Dir[File.expand_path('~/.ssh/*.pem')].detect do |path|
        generate_ec2_key_fingerprint(path) == key_fingerprint
      end

      unless path
        raise UserMessageError, "Could not find #{key_name.inspect} SSH key with fingerprint #{key_fingerprint}"
      end

      path
    end

    def bastion_gateway
      @bastion_gateway ||= Net::SSH::Gateway.new(
        bastion_instance.public_dns_name,
        'root',
      )
    end

    def with_pg_env(app_name)
      environment_name = app_environments.fetch(app_name).values.first.environment_name
      database_uri = URI.parse(get_environment_config_vars(environment_name).fetch('DATABASE_URL'))

      unless database_uri.scheme == 'postgresql'
        raise "Expected PostgreSQL URL: #{database_uri}"
      end

      bastion_gateway.open database_uri.hostname, database_uri.port || 5432 do |local_port|
        env = {
          'PGHOST' => '127.0.0.1',
          'PGPORT' => local_port.to_s,
          'PGUSER' => database_uri.user,
          'PGPASSWORD' => database_uri.password,
          'PGDATABASE' => database_uri.path.sub(%r{^/}, ''),
        }

        ClimateControl.modify(env) { yield }
      end
    end

    def instance_ssh_cmd(instance_id, tty: false)
      instance = find_instance(
        'instance-id' => instance_id,
      )

      proxy_cmd = <<-SH.squish
        ssh
        -W %h:%p
        root@#{Shellwords.escape bastion_instance.public_dns_name}
      SH

      <<-SH.squish
        ssh
        -o UserKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=no
        -o LogLevel=#{tty ? 'quiet' : 'error'}
        #{tty ? '-t' : nil}
        -o ProxyCommand=#{Shellwords.escape proxy_cmd}
        -i #{Shellwords.escape identity_path(instance.key_name)}
        ec2-user@#{Shellwords.escape instance.private_dns_name}
      SH
    end

    def docker_run_cmd(tty: false)
      <<-SH.strip_heredoc.strip
        set -euo pipefail
        ENV_FILE="$(mktemp -t enops-run-env.XXXXXX)"
        trap 'rm "${ENV_FILE?}"' EXIT
        sudo /opt/elasticbeanstalk/containerfiles/support/generate_env > "${ENV_FILE?}"
        IMAGE_ID="$(cat /etc/elasticbeanstalk/.aws_beanstalk.staging-image-id 2> /dev/null || cat /etc/elasticbeanstalk/.aws_beanstalk.current-image-id)"
        sudo docker run --rm #{tty ? '--interactive --tty' : nil} --env-file "${ENV_FILE?}" "${IMAGE_ID?}"
      SH
    end

    def instance_docker_run_cmd(instance_id, cmd)
      ssh_cmd = instance_ssh_cmd(instance_id, tty: true)
      "#{ssh_cmd} #{Shellwords.escape "#{docker_run_cmd(tty: true)} sh -c #{Shellwords.escape cmd}"}"
    end

    def docker_log_tail_cmd
      <<-SH.strip_heredoc.strip
        set -euo pipefail
        while true; do
          CONTAINER_ID="$(cat /etc/elasticbeanstalk/.aws_beanstalk.staging-container-id 2> /dev/null || cat /etc/elasticbeanstalk/.aws_beanstalk.current-container-id)"
          sudo docker logs --timestamps --follow --since 1m "${CONTAINER_ID?}" 2>&1 | \
            gawk '{ print substr(CONTAINER_ID, 0, 12) " " $0; fflush(); }' CONTAINER_ID="${CONTAINER_ID?}"
        done
      SH
    end

    def run_on_instances!(instance_ids, cmd)
      instances = ec2_client.describe_instances(
        filters: [{name: 'instance-id', values: instance_ids}],
      ).flat_map(&:reservations).flat_map(&:instances)

      unless instances.size == instance_ids.size
        raise "Could not find instance: #{(instance_ids - instances.map(&:instance_id)).map(&:inspect).join(', ')}"
      end

      ssh_sessions = []
      threads = instances.map do |instance|
        Thread.new do
          env_name = instance.tags.detect { |tag| tag.key == 'elasticbeanstalk:environment-name' }.value
          instance_id = instance.instance_id

          ssh_session = bastion_gateway.ssh(
            instance.private_dns_name,
            'ec2-user',
            keys: [identity_path(instance.key_name)],
          )
          ssh_sessions << ssh_session

          buffers = {stdout: '', stderr: ''}
          status = {}

          output = lambda do |stream, line|
            unless line.empty?
              Kernel.const_get(stream.upcase).puts "#{env_name} #{instance_id} #{line.chomp}"
            end
          end

          ssh_session.exec! cmd, status: status do |channel, stream, data|
            buffer = buffers.fetch(stream)
            buffer << data
            while pos = buffer.index("\n")
              line = buffer.slice!(0, pos + 1)
              output.call stream, line
            end
          end

          buffers.each do |stream, data|
            output.call stream, data
          end

          exit_code = status.fetch(:exit_code)
          unless exit_code == 0
            status = Struct.new(:exitstatus).new(exit_code)
            raise ExecuteError.new(cmd: cmd, status: status, output: nil)
          end
        end
      end

      begin
        threads.each(&:join)
      ensure
        ssh_sessions.each(&:shutdown!)
      end
    end

    def s3_bucket
      @s3_bucket ||= eb_client.create_storage_location.s3_bucket
    end

    def repository
      @repository ||= begin
        repositories = ecr_client.describe_repositories(repository_names: [APPLICATION_NAME]).flat_map(&:repositories)
        unless repositories.size == 1
          raise "Expect to find 1 ECR repository but found #{repositories.size}"
        end
        repositories.first
      end
    end

    def image_exists?(version_label)
      images = ecr_client.batch_get_image(
        repository_name: repository.repository_name,
        image_ids: [{image_tag: version_label}],
      ).flat_map(&:images)

      !images.empty?
    end

    def build_dockerrun_json(version_label)
      unless image_exists?(version_label)
        raise UserMessageError, "Could not find image for #{version_label.inspect}"
      end

      data = {
        AWSEBDockerrunVersion: "1",
        Image: {
          Name: "#{repository.repository_uri}:#{version_label}",
          Update: 'true'
        },
        Command: "sh -c 'exec $CMD'",
        Ports: [
          {
            ContainerPort: '3000'
          },
        ],
        Logging: '/app/log',
      }

      JSON.pretty_generate(data)
    end

    def get_file_content(name)
      File.read("#{File.dirname(__FILE__)}/data/elastic_beanstalk/#{name}")
    end

    def patch_command(patch_path)
      {
        test: "patch --forward --dry-run --directory=/ --strip=0 --input=#{patch_path}",
        command: "patch --force --directory=/ --strip=0 --input=#{patch_path}",
      }
    end

    def ebextensions
      {
        migrations: {
          container_commands: {
            migrations: {
              command: "#{docker_run_cmd} bundle exec rake db:migrate",
            },
          },
        },
        delay_bad_gateway: {
          packages: {
            yum: {
              'patch' => [],
              'nginx-mod-http-perl' => [],
            }
          },
          files: {
            '/etc/nginx/perl/lib/delay.pm' => {
              content: get_file_content('delay_bad_gateway/delay.pm'),
            },
            '/etc/nginx/conf.d/delay.conf' => {
              content: get_file_content('delay_bad_gateway/delay.conf'),
            },
            '/etc/nginx/nginx.conf.delay.patch' => {
              content: get_file_content('delay_bad_gateway/nginx.conf.patch'),
            },
            '/opt/elasticbeanstalk/hooks/common.sh.delay.patch' => {
              content: get_file_content('delay_bad_gateway/hooks_common.patch'),
            }
          },
          commands: {
            patch_nginx_conf: patch_command('/etc/nginx/nginx.conf.delay.patch'),
            patch_eb_hook: patch_command('/opt/elasticbeanstalk/hooks/common.sh.delay.patch'),
          },
        },
        request_start: {
          files: {
            '/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.request_start.patch' => {
              content: get_file_content('request_start/docker_proxy.conf.patch'),
            },
          },
          commands: {
            patch_docker_proxy_conf: patch_command('/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.request_start.patch'),
          },
        },
        log_format: {
          files: {
            '/etc/nginx/conf.d/log_format.conf' => {
              content: get_file_content('log_format/log_format.conf'),
            },
            '/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.log_format.patch' => {
              content: get_file_content('log_format/docker_proxy.conf.patch'),
            },
          },
          commands: {
            patch_docker_proxy_conf: patch_command('/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.log_format.patch'),
          },
        },
        reject_bad_host: {
          files: {
            '/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.reject_bad_host.patch' => {
              content: get_file_content('reject_bad_host/docker_proxy.conf.patch'),
            },
          },
          commands: {
            patch_docker_proxy_conf: patch_command('/etc/nginx/sites-available/elasticbeanstalk-nginx-docker-proxy.conf.reject_bad_host.patch'),
          },
        },
      }
    end

    def create_source_bundle(version_label)
      tempfile = Tempfile.new(['encopy-beanstalk', '.zip'])
      tempfile.close

      ::Zip::File.open(tempfile.path, ::Zip::File::CREATE) do |zipfile|
        zipfile.get_output_stream('Dockerrun.aws.json') do |io|
          io.write build_dockerrun_json(version_label)
        end

        ebextensions.each do |name, data|
          zipfile.get_output_stream(".ebextensions/#{name}.config") do |io|
            io.write JSON.pretty_generate(data)
          end
        end
      end

      s3_key = "source/#{version_label}.zip"

      File.open tempfile.path, external_encoding: 'binary' do |io|
        s3_client.put_object(
          bucket: s3_bucket,
          key: s3_key,
          acl: 'private',
          body: io,
        )
      end

      s3_key
    ensure
      tempfile.unlink
    end

    def create_app_version(version_label)
      s3_key = create_source_bundle(version_label)

      versions = eb_client.describe_application_versions(
        application_name: APPLICATION_NAME,
        version_labels: [version_label],
      ).flat_map(&:application_versions)

      if versions.size > 1
        raise "Found more than one application version matching #{version_label.inspect}"
      end
      version = versions.first

      if version
        if version.source_bundle.s3_bucket == s3_bucket && version.source_bundle.s3_key == s3_key
          return version
        end
      end

      eb_client.create_application_version(
        application_name: APPLICATION_NAME,
        version_label: version_label,
        source_bundle: {
          s3_bucket: s3_bucket,
          s3_key: s3_key,
        },
      )
    end
  end
end
