# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'enops/version'

Gem::Specification.new do |spec|
  spec.name = 'enops'
  spec.version = Enops::VERSION
  spec.authors = ['Ennova']
  spec.email = ['dev@ennova.com.au']

  spec.summary = 'Various DevOps related classes and modules for Ennova.'
  spec.homepage = 'https://github.com/ennova/enops'

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.required_ruby_version = '~> 2.4'

  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_dependency 'netrc'
  spec.add_dependency 'heroics', '~> 0.0.24'
  spec.add_dependency 'retryable', '~> 2.0'
  spec.add_dependency 'activesupport', '>= 4.0', '< 6.0'
  spec.add_dependency 'aws-sdk-elasticbeanstalk', '~> 1.8'
  spec.add_dependency 'aws-sdk-ec2', '~> 1.41'
  spec.add_dependency 'aws-sdk-ecr', '~> 1.4'
  spec.add_dependency 'aws-sdk-s3', '~> 1.17'
  spec.add_dependency 'net-ssh-gateway', '~> 2.0'
  spec.add_dependency 'climate_control', '~> 0.2.0'
  spec.add_dependency 'rubyzip', '~> 1.2'
end
