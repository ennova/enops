require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new do |task|
  task.libs << 'test'
  task.pattern = 'test/**/*_test.rb'
end

task default: :test

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
