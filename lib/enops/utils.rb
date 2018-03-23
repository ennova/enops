require 'retryable'
require 'active_support/core_ext/hash/except'
require 'pty'
require 'open3'

module Enops
  class ExecuteError < StandardError
    attr_reader :cmd, :status, :output

    def initialize(options = {})
      @cmd = options.fetch(:cmd)
      @status = options.fetch(:status)
      @output = options.fetch(:output)

      super "#{cmd.inspect} failed with exit status #{status.exitstatus}"
    end
  end

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
      options = {pty: true, quiet: false}.merge(options)

      output_io = StringIO.new

      status = if options.fetch(:pty)
        PTY.spawn "(#{cmd}) 2>&1" do |r, w, pid|
          log_io_lines(r, output_io, options.fetch(:quiet), &block)
          Process.wait(pid)
        end
        $?
      else
        Open3.popen2 "(#{cmd}) 2>&1" do |stdin, stdout, wait_thread|
          log_io_lines(stdout, output_io, options.fetch(:quiet), &block)
          wait_thread.value
        end
      end

      unless status.success?
        raise ExecuteError.new(cmd: cmd, status: status, output: output_io.string)
      end

      output_io.string
    end

    private

    def log_io_lines(src, dst, quiet)
      begin
        loop do
          line = src.readline
          dst << line
          if block_given?
            yield line
          elsif !quiet
            Enops.logger.debug line.chomp
          end
        end
      rescue EOFError, Errno::EIO
      end
    end
  end
end
