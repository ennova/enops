# Enops

Various DevOps related classes and modules for Ennova.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'enops', github: 'ennova/enops'
```

And then execute:

```
bundle
```

## Usage

##### Common setup

```ruby
require 'logger'
require 'enops'
Enops.logger = Logger.new(STDOUT)
```

### `Enops::Heroku`

Handy methods for managing a Heroku app:

- Execute Heroku Toolbelt commands via the `cmd` method
- Run commands on a Heroku dyno via the `run` method
- Query the Heroku API via the `client` method
- Convenience methods, e.g. `app_names`, `get_config_vars`

##### Example usage

```ruby
heroku = Enops::Heroku.new('username', '*******')
heroku.run('app-name', 'rake db:migrate')
```

### `Enops::Utils.with_retry`

Runs a code block, and retries it when an exception occurs.

##### Example usage

```ruby
count = 0
Enops::Utils.with_retry(tries: 10, sleep: 2, on: RuntimeError) do
  count += 1
  puts "count: #{count}"
  raise RuntimeError if count <= 3
  puts 'success!'
end
```

Outputs:

```text
count: 1
… WARN -- : Retrying irb_binding (try 2 of 10)
count: 2
… WARN -- : Retrying irb_binding (try 3 of 10)
count: 3
… WARN -- : Retrying irb_binding (try 4 of 10)
count: 4
success!
```

### `Enops::Utils.execute`

Executes a terminal command. Raises an error if the command isn't successful.

##### Example usage

```ruby
Enops::Utils.execute 'pwd'
```

Outputs:

```text
… DEBUG -- : /Users/ennova/enops
```

If you want to do something with the output, pass the method a block:

```ruby
Enops::Utils.execute 'pwd' do |line|
  Enops.logger.info "You are here: #{line.chomp}"
end
```

Outputs:

```text
… INFO -- : You are here: /Users/ennova/enops
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.
