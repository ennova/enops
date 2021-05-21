require 'enops/aws_auth'
require 'aws-sdk-s3'
require 'aws-sdk-cloudwatch'
require 'parallel'
require 'ruby-progressbar'
require 'active_support/core_ext/object/deep_dup'

module Enops
  module AwsS3
    class Sync
      attr_reader :source_bucket_name
      attr_reader :source_profile_name
      attr_reader :source_bucket_region
      attr_reader :dest_bucket_name
      attr_reader :dest_profile_name
      attr_reader :dest_bucket_region
      attr_reader :prefix
      attr_reader :exclude_prefix
      attr_reader :only_missing

      def initialize(source_bucket_name:, source_profile_name: nil, source_bucket_region: nil, dest_bucket_name:, dest_profile_name: nil, dest_bucket_region: nil, prefix: nil, exclude_prefix: nil, only_missing: false)
        @source_bucket_name = source_bucket_name
        @source_profile_name = source_profile_name
        @source_bucket_region = source_bucket_region
        @dest_bucket_name = dest_bucket_name
        @dest_profile_name = dest_profile_name
        @dest_bucket_region = dest_bucket_region
        @prefix = prefix
        @exclude_prefix = exclude_prefix
        @only_missing = only_missing
      end

      def sync!
        source_keys = get_bucket_keys(:source)
        keys_to_skip = only_missing ? get_bucket_keys(:dest) : []
        keys_to_copy = source_keys - keys_to_skip
        if exclude_prefix
          keys_to_copy.reject! { |key| key.start_with?(exclude_prefix) }
        end

        if keys_to_copy.empty?
          puts 'Nothing to do.'
        else
          grant_source_bucket_read unless same_bucket_owner?
          copy_objects keys_to_copy
          revoke_source_bucket_read unless same_bucket_owner?
        end
      end

      private

      def with_progress_bar(total:, title: nil)
        puts "#{title}..." if title
        bar = ProgressBar.create total: total, format: '%e %B %p%% [%c/%C]', length: [ProgressBar::Calculators::Length.new.length, 80].min, unknown_progress_animation_steps: ['.'], throttle_rate: 0.1
        result = yield bar
        bar.finish
        result
      end

      def parallel_each(objects, title:, threads:)
        mutex = Mutex.new
        with_progress_bar total: objects.size, title: title do |bar|
          Parallel.each objects, in_threads: threads do |object|
            yield object

            mutex.synchronize do
              bar.increment
            end
          end
        end
      end

      def get_bucket_keys(type)
        puts "Fetching #{type} keys..."

        statistics = cloudwatch_client_for(type).get_metric_statistics(
          namespace: 'AWS/S3',
          metric_name: 'NumberOfObjects',
          dimensions: [
            {name: 'BucketName', value: bucket_name_for(type)},
            {name: 'StorageType', value: 'AllStorageTypes'},
          ],
          statistics: %w[Maximum],
          start_time: Time.now - 86400 * 7,
          end_time: Time.now,
          period: 86400,
        )
        total = statistics.datapoints.sort_by(&:timestamp).last&.maximum
        total = Integer(total) if total

        total = nil if prefix

        with_progress_bar total: total, title: nil do |bar|
          keys = []
          page = s3_client_for(type).list_objects_v2(bucket: bucket_name_for(type), prefix: prefix, max_keys: 1000)
          loop do
            keys += page.contents.map(&:key)
            if bar.total && bar.total < keys.size
              bar.total = keys.size
            end
            bar.progress = keys.size
            break unless page.next_page?
            page = page.next_page
          end
          keys
        end
      end

      def copy_objects(keys)
        parallel_each keys, title: 'Copying objects', threads: 50 do |key|
          copy_object key
        end
      end

      def copy_object(key)
        dest_s3_client.copy_object(copy_source: "/#{source_bucket_name}/#{key}", bucket: dest_bucket_name, key: key)
        source_acl = source_s3_client.get_object_acl(bucket: source_bucket_name, key: key).to_hash
        dest_acl = translate_acl_owner(source_acl)
        dest_s3_client.put_object_acl(bucket: dest_bucket_name, key: key, access_control_policy: dest_acl)
      rescue Aws::Errors::ServiceError => e
        STDERR.puts "Error copying #{key}: #{e}"
        dest_s3_client.delete_object bucket: dest_bucket_name, key: key
        raise
      end

      def get_bucket_owner(type)
        s3_client_for(type).get_bucket_acl(bucket: bucket_name_for(type)).owner
      end

      def source_bucket_owner
        @source_bucket_owner ||= get_bucket_owner(:source)
      end

      def dest_bucket_owner
        @dest_bucket_owner ||= get_bucket_owner(:dest)
      end

      def verify_expected_source_bucket_acl!
        acl = source_s3_client.get_bucket_acl(bucket: source_bucket_name)

        unless acl.owner == source_bucket_owner
          STDERR.puts "Expected source bucket to be owned by #{source_bucket_owner}"
          exit 1
        end

        unexpected_grants = acl.grants.reject do |grant|
          grant.grantee.id == source_bucket_owner.id && grant.permission == 'FULL_CONTROL'
        end.reject do |grant|
          grant.grantee.id == dest_bucket_owner.id && grant.permission == 'READ'
        end

        unless unexpected_grants.empty?
          STDERR.puts "Expected grants on source bucket: #{unexpected_grants.inspect}"
          exit 1
        end
      end

      def dest_account_id
        @dest_account_id ||= Integer(dest_sts_client.get_caller_identity.account)
      end

      def source_bucket_policy
        {
          "Version" => "2008-10-17",
          "Statement": [
            {
              "Sid": "enops-aws-s3-sync-temp",
              "Effect": "Allow",
              "Principal": {
                "AWS": "arn:aws:iam::#{dest_account_id}:root",
              },
              "Action": [
                "s3:ListBucket",
                "s3:GetObject",
              ],
              "Resource": [
                "arn:aws:s3:::#{source_bucket_name}",
                "arn:aws:s3:::#{source_bucket_name}/*",
            ]
            },
          ],
        }.to_json
      end

      def verify_expected_source_bucket_policy!
        policy_json = source_s3_client.get_bucket_policy(bucket: source_bucket_name).policy.read
        unless JSON.parse(policy_json) == JSON.parse(source_bucket_policy)
          STDERR.puts "Unexpected source bucket policy"
          exit 1
        end
      rescue Aws::S3::Errors::NoSuchBucketPolicy
      end

      def same_bucket_owner?
        source_bucket_owner.id == dest_bucket_owner.id
      end

      def grant_source_bucket_read
        puts "Granting source bucket read permission to target bucket owner..."
        verify_expected_source_bucket_policy!
        source_s3_client.put_bucket_policy bucket: source_bucket_name, policy: source_bucket_policy
        verify_expected_source_bucket_policy!
      end

      def revoke_source_bucket_read
        puts "Resetting source bucket permissions..."
        verify_expected_source_bucket_acl!
        source_s3_client.delete_bucket_policy bucket: source_bucket_name
        verify_expected_source_bucket_acl!
      end

      def translate_acl_owner(acl)
        acl = acl.deep_dup

        update_owner_id_fn = lambda do |hash|
          next if hash.fetch(:type, nil) == 'Group' && !hash.key?(:id)
          if hash.fetch(:id) == source_bucket_owner.id
            hash[:id] = dest_bucket_owner.id
          end
        end

        update_owner_id_fn.call acl.fetch(:owner)
        acl.fetch(:grants).each do |grant|
          update_owner_id_fn.call grant.fetch(:grantee)
        end

        acl
      end

      def credentials_for(type)
        profile_name = public_send("#{type}_profile_name")

        if profile_name
          Enops::AwsAuth.cli_credentials(profile_name: profile_name)
        else
          Enops::AwsAuth.default_credentials
        end
      end

      def region_for(type)
        profile_name = public_send("#{type}_profile_name")
        region_name = public_send("#{type}_bucket_region")

        region = if region_name
          region_name
        elsif profile_name
          Enops::AwsAuth.cli_region(profile_name: profile_name)
        else
          Enops::AwsAuth.default_region
        end
      end

      def source_s3_client
        @source_s3_client ||= Aws::S3::Client.new(
          credentials: credentials_for(:source),
          region: region_for(:source),
        )
      end

      def dest_s3_client
        @dest_s3_client ||= Aws::S3::Client.new(
          credentials: credentials_for(:dest),
          region: region_for(:dest),
        )
      end

      def s3_client_for(type)
        send("#{type}_s3_client")
      end

      def dest_sts_client
        @dest_sts_client ||= Aws::STS::Client.new(
          credentials: credentials_for(:dest),
          region: region_for(:dest),
        )
      end

      def source_cloudwatch_client
        @source_cloudwatch_client ||= Aws::CloudWatch::Client.new(
          credentials: credentials_for(:source),
          region: region_for(:source),
        )
      end

      def dest_cloudwatch_client
        @dest_cloudwatch_client ||= Aws::CloudWatch::Client.new(
          credentials: credentials_for(:dest),
          region: region_for(:dest),
        )
      end

      def cloudwatch_client_for(type)
        send("#{type}_cloudwatch_client")
      end

      def bucket_name_for(type)
        send("#{type}_bucket_name")
      end
    end
  end
end
