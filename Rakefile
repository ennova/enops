require 'bundler/gem_tasks'

desc 'Open development console'
task :console do
  exec <<~SH
    ruby \
      -rbundler/setup \
      -Ilib -renops \
      -e 'Enops.logger = Logger.new(STDOUT)' \
      -e 'TOPLEVEL_BINDING.eval("self").define_singleton_method(:heroku) { Enops::Heroku.default }' \
      -rpry -e 'Pry::CLI.start(Pry::CLI.parse_options)'
  SH
end
