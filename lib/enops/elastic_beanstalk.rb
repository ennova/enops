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
    ECR_REGISTRY_ID = '252974019764'
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

    def app_version(app_name)
      app_versions[app_name] or raise UserMessageError, "Error getting application version for #{app_name.inspect}"
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

    def set_config_vars(app_name, config_vars, env_types: nil)
      envs = app_environments.fetch(app_name).map do |env_type, environment|
        [env_type, environment.environment_name]
      end.to_h

      if env_types
        envs = envs.slice(*env_types)
      end

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

          add_option_setting(
            env_type_updates[env_type],
            namespace: CONFIG_VAR_NAMESPACE,
            option_name: key,
            value: value,
          )
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

          add_option_setting(
            env_type_updates[env_type],
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
        Enops::Utils.execute_interactive cmd
      end
    end

    def run_app_cmd!(app_name, cmd)
      instances = get_instances(app_name)
      instance_id = instances.fetch('worker', []).sample || instances.values.flatten.sample

      Enops::Utils.execute_interactive instance_docker_run_cmd(instance_id, cmd)
    end

    def pg_restore!(app_name, backup_url)
      run_app_cmd! app_name, <<-SH.strip_heredoc.strip
        wget -O /tmp/backup.dump #{Shellwords.escape backup_url}
        pg_restore -l /tmp/backup.dump | egrep -v '; 0 0 (ACL|DATABASE PROPERTIES|COMMENT - EXTENSION) ' > /tmp/backup.list
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
      Enops::Utils.execute_interactive "#{instance_ssh_cmd(instance_id)} #{Shellwords.escape cmd}"
    end

    def tail_app_log!(app_name, env_type: nil)
      instance_ids = if env_type
        get_instances(app_name).fetch(env_type)
      else
        get_instances(app_name).values.flatten
      end
      run_on_instances! instance_ids, docker_log_tail_cmd
    end

    def available_versions
      image_details = ecr_client.describe_images(
        registry_id: ECR_REGISTRY_ID,
        repository_name: APPLICATION_NAME,
      ).flat_map(&:image_details).sort_by(&:image_pushed_at)

      image_details.map do |image_detail|
        version_labels = Array(image_detail.image_tags).sort_by do |version_label|
          priority = case version_label
          when /^ref-/
            0
          when /^v/
            1
          else
            2
          end

          [priority, version_label]
        end

        {
          version_labels: version_labels,
          created_at: image_detail.image_pushed_at,
        }
      end
    end

    def start_deploy(app_name:, version_label:, immutable:, env_types: nil, config_vars: nil)
      create_app_version version_label

      environments = app_environments.fetch(app_name)
      env_types ||= environments.keys
      environments = env_types.flat_map { |env_type| environments.fetch(env_type) }

      environments.map do |environment|
        params = {
          environment_name: environment.environment_name,
          version_label: version_label,
        }

        add_option_setting(
          params,
          namespace: 'aws:elasticbeanstalk:command',
          option_name: 'DeploymentPolicy',
          value: immutable ? 'Immutable' : 'AllAtOnce',
        )

        config_vars&.each do |key, value|
          add_option_setting(
            params,
            namespace: CONFIG_VAR_NAMESPACE,
            option_name: key,
            value: value,
          )
        end

        eb_client.update_environment(params)
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
        eb_client.describe_environments.flat_map(&:environments)
          .select { |environment| environment.application_name == APPLICATION_NAME }
          .index_by(&:environment_name)
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

    def add_option_setting(update_params, namespace:, option_name:, value:)
      unless value.nil?
        update_params[:option_settings] ||= []
        update_params[:option_settings] << Aws::ElasticBeanstalk::Types::ConfigurationOptionSetting.new(
          namespace: namespace,
          option_name: option_name,
          value: value,
        )
      else
        update_params[:options_to_remove] ||= []
        update_params[:options_to_remove] << Aws::ElasticBeanstalk::Types::OptionSpecification.new(
          namespace: namespace,
          option_name: option_name,
        )
      end
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
      @bastion_instance ||= find_instance(
        'instance.group-name' => 'bastion'
      )
    end

    def bastion_instance_hostname
      if bastion_instance.public_dns_name.blank?
        raise "Expected bastion host #{bastion_instance.instance_id} to have a public DNS name"
      end
      hostname = bastion_instance.tags.detect { |tag| tag.key == 'Name' && tag.value.start_with?('bastion.') }&.value
      hostname ||= bastion_instance.public_dns_name
      hostname
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
        bastion_instance_hostname,
        'root',
        loop_wait: 0.1,
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
        root@#{Shellwords.escape bastion_instance_hostname}
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
        repositories = ecr_client.describe_repositories(registry_id: ECR_REGISTRY_ID, repository_names: [APPLICATION_NAME]).flat_map(&:repositories)
        unless repositories.size == 1
          raise "Expect to find 1 ECR repository but found #{repositories.size}"
        end
        repositories.first
      end
    end

    def image_exists?(version_label)
      images = ecr_client.batch_get_image(
        registry_id: repository.registry_id,
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
      }

      JSON.pretty_generate(data)
    end

    def get_file_content(name)
      File.read("#{File.dirname(__FILE__)}/data/elastic_beanstalk/#{name}")
    end

    def extract_patch_target_path(content)
      target_paths = content.scan(/^[+]{3} ([^\t\n ]+)/).flatten
      raise ArgumentError unless target_paths.size == 1
      target_paths.first
    end

    def make_patch_path(name, target_path)
      "#{target_path}.#{File.dirname(name)}.patch"
    end

    def config_file(name, path, mode: '644')
      raise ArgumentError unless mode =~ /^[0-7]{3}$/
      raise ArgumentError if name.end_with?('.patch')

      {
        path => {
          mode: "000#{mode}",
          content: get_file_content(name),
        },
      }
    end

    def patch_file(name)
      raise ArgumentError unless name.end_with?('.patch')

      content = get_file_content(name)
      target_path = extract_patch_target_path(content)
      patch_path = make_patch_path(name, target_path)

      {
        patch_path => {
          content: content,
        },
      }
    end

    def patch_command(name, success_content)
      raise ArgumentError unless name.end_with?('.patch')

      content = get_file_content(name)
      target_path = extract_patch_target_path(content)
      patch_path = make_patch_path(name, target_path)

      command_name = "patch_#{name.sub(/\.patch$/, '').gsub(/[\/.]/, '_')}"
      test_command = "grep -qF #{Shellwords.escape success_content} #{Shellwords.escape target_path}"
      patch_command = "patch --force --ignore-whitespace --directory=/ --strip=0 --input=#{patch_path}"

      {
        command_name.to_sym => {
          command: "#{test_command} || #{patch_command} && #{test_command}",
        },
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
          files: [
            config_file('delay_bad_gateway/delay.pm', '/etc/nginx/perl/lib/delay.pm'),
            config_file('delay_bad_gateway/delay.conf', '/etc/nginx/conf.d/delay.conf'),
            patch_file('delay_bad_gateway/nginx.conf.patch'),
            patch_file('delay_bad_gateway/hooks_common.patch'),
          ].inject(:merge),
          commands: [
            patch_command('delay_bad_gateway/nginx.conf.patch', 'ngx_http_perl_module'),
            patch_command('delay_bad_gateway/hooks_common.patch', 'server 127.0.0.1:8501'),
          ].inject(:merge),
        },
        request_start: {
          files: [
            patch_file('request_start/docker_proxy.conf.patch'),
          ].inject(:merge),
          commands: [
            patch_command('request_start/docker_proxy.conf.patch', 'X-Request-Start'),
          ].inject(:merge),
        },
        log_format: {
          files: [
            config_file('log_format/log_format.conf', '/etc/nginx/conf.d/log_format.conf'),
            patch_file('log_format/docker_proxy.conf.patch'),
          ].inject(&:merge),
          commands: [
            patch_command('log_format/docker_proxy.conf.patch', 'access.log combined_extra'),
          ].inject(&:merge),
        },
        reject_bad_host: {
          files: [
            patch_file('reject_bad_host/docker_proxy.conf.patch'),
          ].inject(:merge),
          commands: [
            patch_command('reject_bad_host/docker_proxy.conf.patch', 'reject_bad_host'),
          ].inject(:merge),
        },
        request_id: {
          files: [
            patch_file('request_id/docker_proxy.conf.patch'),
            patch_file('request_id/log_format.conf.patch'),
          ].inject(:merge),
          commands: [
            patch_command('request_id/docker_proxy.conf.patch', 'x_request_id'),
            patch_command('request_id/log_format.conf.patch', 'x_request_id'),
          ].inject(:merge),
        },
        wait_for_staging_port: {
          files: [
            patch_file('wait_for_staging_port/00run.sh.patch'),
          ].inject(:merge),
          commands: [
            patch_command('wait_for_staging_port/00run.sh.patch', 'nc -zd'),
          ].inject(:merge),
        },
        restart_logging: {
          files: [
            config_file('restart_logging/restart_logging.sh', '/opt/elasticbeanstalk/hooks/appdeploy/post/99_restart_logging.sh', mode: '755'),
          ].inject(&:merge),
        }
      }
    end

    def create_source_bundle(version_label)
      tempfile = Tempfile.new(['encopy-beanstalk', '.zip'])
      tempfile.close

      ::Zip::File.open(tempfile.path, ::Zip::File::CREATE) do |zipfile|
        zipfile.get_output_stream('Dockerrun.aws.json') do |io|
          io.write build_dockerrun_json(version_label)
        end

        ebextensions.each_with_index do |(name, data), index|
          zipfile.get_output_stream(".ebextensions/#{'%02d' % [index+1]}_#{name}.config") do |io|
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
