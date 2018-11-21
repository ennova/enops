require 'retryable'
require 'active_support/core_ext/hash/except'
require 'pty'
require 'open3'

module Enops
  class ExecuteError < StandardError
    attr_reader :cmd, :status, :output

    def initialize(cmd:, status:, output:)
      @cmd = cmd
      @status = status
      @output = output

      super "#{cmd.inspect} failed with exit status #{status.exitstatus}"
    end
  end

  module Utils
    extend self

    def caller_label
      caller[1][/`([^']*)'$/, 1]
    end

    def with_retry(tries:, sleep:, on: StandardError, caller_label: self.caller_label)
      Retryable.retryable(tries: tries, sleep: sleep, on: on) do |try_num|
        Enops.logger.warn "Retrying #{caller_label} (try #{try_num+1} of #{tries})" if try_num > 0
        yield
      end
    end

    def execute(cmd, pty: true, quiet: false, &block)
      output_io = StringIO.new

      status = if pty
        PTY.spawn "(#{cmd}) 2>&1" do |r, w, pid|
          log_io_lines(src: r, dst: output_io, quiet: quiet, &block)
          Process.wait(pid)
        end
        $?
      else
        Open3.popen2 "(#{cmd}) 2>&1" do |stdin, stdout, wait_thread|
          log_io_lines(src: stdout, dst: output_io, quiet: quiet, &block)
          wait_thread.value
        end
      end

      unless status.success?
        raise ExecuteError.new(cmd: cmd, status: status, output: output_io.string)
      end

      output_io.string
    end

    def execute_interactive(cmd)
      system cmd
      unless $?.success?
        raise ExecuteError.new(cmd: cmd, status: $?, output: nil)
      end
    end

    private

    def log_io_lines(src:, dst:, quiet:)
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
