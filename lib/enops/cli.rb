require 'clamp'
require 'tty-table'
require 'aws-sdk-core/errors'

STDOUT.sync = true

module Enops
  module CLI
    class MainCommand < Clamp::Command
    end

    module ErrorHandling
      def execute
        super
      rescue Enops::UserMessageError, Enops::ExecuteError, ::Aws::Errors::ServiceError, ::Aws::Errors::MissingCredentialsError, ::Aws::Errors::InvalidProcessCredentialsPayload, ::Aws::Errors::MissingRegionError => e
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
  end
end

Clamp.allow_options_after_parameters = true

require 'enops/cli/aws'
require 'enops/cli/elastic_beanstalk'
require 'enops/cli/setup'
