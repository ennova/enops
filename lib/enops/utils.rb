require 'retryable'
require 'active_support/core_ext/hash/except'
require 'pty'
require 'open3'

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

    def execute(cmd, options = {}, &block)
      options = {pty: true}.merge(options)

      output_io = StringIO.new

      status = if options.fetch(:pty)
        PTY.spawn "(#{cmd}) 2>&1" do |r, w, pid|
          log_io_lines(r, output_io, &block)
          Process.wait(pid)
        end
        $?
      else
        Open3.popen2 "(#{cmd}) 2>&1" do |stdin, stdout, wait_thread|
          log_io_lines(stdout, output_io, &block)
          wait_thread.value
        end
      end

      raise "#{cmd.inspect} failed with exit status #{status.exitstatus}" unless status.success?

      output_io.string
    end

    private

    def log_io_lines(src, dst)
      begin
        loop do
          line = src.readline
          dst << line
          if block_given?
            yield line
          else
            Enops.logger.debug line.chomp
          end
        end
      rescue EOFError, Errno::EIO
      end
    end
  end
end
