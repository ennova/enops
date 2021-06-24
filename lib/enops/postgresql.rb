require 'pg'

module Enops
  module PostgreSQL
    extend self

    def pg_restore_script_path
      File.dirname(__FILE__) + '/support/enops_pg_restore'
    end

    def wait_for_connections_to_close(database_url)
      sql = <<-SQL.gsub(/\s+/, ' ').strip
        SELECT pid, application_name
        FROM pg_stat_activity
        WHERE
          datname = current_database() AND
          usename = current_user AND
          pid != pg_backend_pid() AND
          application_name NOT LIKE 'Heroku+Postgres+-%' AND
          application_name NOT LIKE 'Heroku Postgres -%' AND
          application_name NOT LIKE 'rdsadmin' AND
          application_name NOT LIKE 'postgres_fdw' AND
          application_name NOT LIKE 'PostgreSQL JDBC Driver' AND
          application_name NOT LIKE 'queue_lock'
      SQL

      conn = PG.connect(database_url, connect_timeout: 10)

      Retryable.retryable tries: 10, sleep: 5, on: Timeout::Error do
        logger.debug "Checking database connections..."
        result = conn.exec(sql)

        logger.debug "#{result.entries.size} database connections"

        if result.entries.size > 0
          raise Timeout::Error, "Waiting for DB connections to close: #{result.entries.map { |row| "#{row.fetch('application_name').inspect} (#{row.fetch('pid')})" }.join(', ')}"
        end
      end

    ensure
      conn.close
    end

    private

    def logger
      Enops.logger
    end
  end
end
