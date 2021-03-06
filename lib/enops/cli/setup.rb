module Enops::CLI::Setup
  class MainCommand < Enops::CLI::Command
    def execute
      if File.exists?('bin/enops')
        install_bin_stub
      else
        puts 'Enops setup running outside project directory. Skipping installation of bin stub.'
      end

      Enops::CLI::Aws::ConfigureCommand.new(nil).execute
    end

    def install_bin_stub
      bin_dir = File.expand_path('~/.aws/enops/bin')
      FileUtils.mkdir_p bin_dir

      script_path = "#{bin_dir}/enops"
      File.write script_path, <<~SH
        #!/bin/bash -e

        ENV_FILE="$(mktemp -t enops-env.XXXXXX)"
        trap '{ rm -f "${ENV_FILE?}"; }' EXIT

        (
          "$SHELL" -l -c "
            cd #{Shellwords.escape Dir.pwd} &&
            ruby -rbundler/setup -rshellwords -rrbconfig -e \\"puts \\\\\\"
              export PATH=\#{Shellwords.escape ENV.fetch('PATH')}
              export BUNDLE_GEMFILE=\#{Shellwords.escape Bundler.default_gemfile.to_s}
              export GEM_PATH=\#{Shellwords.escape Gem.paths.path.join(':')}
              ENOPS_BIN=\#{Shellwords.escape Gem.bin_path('enops', 'enops')}
            \\\\\\"\\"
          "
        ) > "${ENV_FILE?}"

        source "${ENV_FILE}"
        rm "${ENV_FILE?}"

        exec ruby "${ENOPS_BIN?}" "$@"
      SH
      FileUtils.chmod '+x', script_path

      FileUtils.mkdir_p File.expand_path('~/bin')
      symlink_path = File.expand_path('~/bin/enops')

      if File.symlink?(symlink_path)
        existing_path = File.readlink(symlink_path)
        if existing_path == script_path
          puts "Enops bin stub at #{symlink_path.inspect}."
          return
        end

        STDERR.puts "#{symlink_path.inspect} already exists but points to #{existing_path.inspect} not #{script_path.inspect}."
        exit 1
      end

      if File.exist?(symlink_path)
        STDERR.puts "#{symlink_path.inspect} already exists but is not a symlink."
        exit 1
      end

      File.symlink script_path, symlink_path
      puts "Enops bin stub installed at #{symlink_path.inspect}."
    end
  end

  Enops::CLI::MainCommand.subcommand 'setup', 'Setup Enops environment', MainCommand
end
