require 'retryable'
require 'active_support/core_ext/hash/except'

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
  end
end
