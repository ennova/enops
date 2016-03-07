require 'retryable'
require 'active_support/core_ext/hash/except'
require 'pty'

module Enops
  module Utils
    extend self

    def caller_label
      caller[1][/`([^']*)'$/, 1]
    end

    def with_retry(options = {})
      options = {tries: 1, caller_label: caller_label}.merge(options)
      retryable_options = options.except(:caller_label)

      Retryable.retryable(retryable_options) do |try_num|
        Enops.logger.warn "Retrying #{options[:caller_label]} (try #{try_num+1} of #{retryable_options[:tries]})" if try_num > 0
        yield
      end
    end

    def execute(cmd)
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
