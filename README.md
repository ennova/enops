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

### `Enops::Heroku`

Handy methods for managing a Heroku app:

- Execute Heroku Toolbelt commands via the `cmd` method
- Run commands on a Heroku dyno via the `run` method
- Query the Heroku API via the `client` method
- Convenience methods, e.g. `app_names`, `get_config_vars`

##### Example usage

```ruby
require 'logger'
require 'enops'

logger = Logger.new(STDOUT)
heroku = Enops::Heroku.new('username', '*******', logger)
heroku.run('app-name', 'rake db:migrate')
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.
