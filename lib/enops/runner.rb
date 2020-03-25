require 'enops/utils'
require 'enops/tarballer'
require 'forwardable'
require 'pty'
require 'io/console'
require 'base64'
require 'shellwords'

module Enops
  class Runner
    extend Forwardable

    module Platform
      class Local
        def call(cmd)
          cmd
        end
      end

      class Remote
        attr_reader :app_name

        def initialize(app_name)
          @app_name = app_name
        end
      end

      class Heroku < Remote
        def call(cmd)
          "CI=true heroku run --exit-code --app #{Shellwords.escape app_name} -- #{Shellwords.escape cmd}"
        end
      end

      class ElasticBeanstalk < Remote
        def call(cmd)
          "enops eb run --app #{Shellwords.escape app_name} -- #{cmd}"
        end
      end
    end

    attr_accessor :platform
    attr_accessor :work_dir
    attr_accessor :extract_path
    attr_accessor :command
    attr_accessor :raise
    attr_accessor :logger

    def initialize
      @platform = Platform::Local.new
      @work_dir = nil
      @extract_path = nil
      @command = 'bash -i'
      @raise = false
    end

    def_delegators :tarballer, :add_file

    def execute
      input_thread = nil

      PTY.spawn(spawn_cmd) do |read, write, pid|
        unless logger
          Signal.trap(:WINCH) { write.winsize = STDOUT.winsize }
          input_thread = Thread.new { IO.copy_stream(STDIN, write) }
        end

        begin
          unless logger
            IO.console&.raw!
          end

          quiet = false
          buf = ''

          loop do
            char = begin
              read.readchar
            rescue EOFError, Errno::EIO
              break
            end

            unless quiet
              output char
            end

            if buf
              buf.concat char
              if buf =~ /(?<! )enops-upload$/
                output "\33[2K\r"
                quiet = true
                buf = ''
                Thread.new { write.write bootstrap_data }
              end
              if buf =~ /(?<! )enops-exec$/
                quiet = false
                buf = nil
              end
            end
          end

          Process.wait(pid)
        ensure
          unless logger
            IO.console&.cooked!
          end
          output nil if logger
        end

        unless $?.success?
          if raise
            raise ExecuteError.new(cmd: cmd, status: $?, output: nil)
          else
            exit $?.exitstatus || 130
          end
        end
      end

      input_thread.kill if input_thread
    end

    private

    def tarballer
      @tarballer ||= Tarballer.new
    end

    def bootstrap_data
      Base64.encode64(tarballer.gzipped_result)
    end

    def bootstrap_script
      <<~SH.tr_s("\n", ';')
        set -euo pipefail
        stty -echo
        echo -en enops\\\\x2dupload
        dd bs=1 count=#{bootstrap_data.bytesize} | base64 --decode | tar zx #{"-C #{Shellwords.escape extract_path}" if extract_path}
        stty echo
        echo -en enops\\\\x2dexec
        #{"cd #{Shellwords.escape(work_dir).sub(/\A\\~/, '~')}" if work_dir}
        exec #{command}
      SH
    end

    def bootstrap_cmd
      "bash -c #{Shellwords.escape bootstrap_script}"
    end

    def spawn_cmd
      platform.call(bootstrap_cmd)
    end

    def output(str)
      if logger
        @output ||= ''
        if str
          @output << str
        else
          @output << "\n" unless @output.empty?
        end
        while @output.match?(/\r?\n/)
          line, @output = @output.split(/\r?\n/, 2)
          line = line.split("\r").inject('') { |buffer, part| buffer[0...part.size] = part; buffer }
          logger.debug line
        end
      else
        STDOUT.write str
      end
    end
  end
end
