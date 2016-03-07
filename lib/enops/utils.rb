require 'retryable'

module Enops
  module Utils
    extend self

    def with_retry(options = {})
      caller_label = caller[0][/`([^']*)'$/, 1]
      retryable_options = {tries: 1}.merge(options)

      Retryable.retryable(retryable_options) do |try_num|
        Enops.logger.warn "Retrying #{caller_label} (try #{try_num+1} of #{retryable_options[:tries]})" if try_num > 0
        yield
      end
    end
  end
end
