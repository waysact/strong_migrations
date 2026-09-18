module StrongMigrations
  module Adapters
    class PostgreSQLAdapter < AbstractAdapter
      # PQTRANS_INTRANS and PQTRANS_INERROR from libpq's public enum.
      # Use numeric values because the pg gem may load after this file.
      IN_TRANSACTION_STATUSES = [2, 3].freeze

      def name
        "PostgreSQL"
      end

      def min_version
        "12"
      end

      def server_version
        @version ||= begin
          target_version(StrongMigrations.target_postgresql_version) do
            version = select_all("SHOW server_version_num").first["server_version_num"].to_i
            # major and minor version
            "#{version / 10000}.#{(version % 10000)}"
          end
        end
      end

      def set_statement_timeout(timeout)
        set_timeout("statement_timeout", timeout)
      end

      def set_transaction_timeout(timeout)
        # TODO make sure true version supports it as well?
        set_timeout("transaction_timeout", timeout) if server_version >= Gem::Version.new("17")
      end

      def set_lock_timeout(timeout, local: false)
        set_timeout("lock_timeout", timeout, local: local)
      end

      # preserve the server's timeout, including role settings and nested overrides
      #
      # The block must not change transaction state. The override and restore
      # both use the state captured before the block. A commit would discard
      # SET LOCAL during the block; a rollback could undo a session-level
      # restore. Restoring the timeout afterward cannot fix either case.
      # Checker only wraps statements that leave transaction state unchanged.
      def with_lock_timeout(timeout)
        return yield if timeout.nil?

        # SHOW starts any lazy Active Record transaction before we check its status
        previous = connection.uncached { select_all("SHOW lock_timeout") }.first["lock_timeout"]
        # use SET LOCAL inside a transaction so restoring a transaction-local value
        # cannot make it persist after commit
        local = server_in_transaction?
        # Track whether this block raised. $! may refer to an exception from
        # an enclosing rescue clause even when this block succeeds.
        operation_failed = false
        # Apply the override inside begin so the ensure clause can restore it
        # if execution is interrupted before yield.
        applied = false
        begin
          set_lock_timeout(timeout, local: local)
          applied = true
          yield
        rescue Exception
          operation_failed = true
          raise
        ensure
          # Preserve the operation's error so retry logic and callers can
          # rescue LockWaitTimeout. Raise a restore error only if the operation
          # succeeded.
          begin
            set_lock_timeout(previous, local: local) if applied
          rescue StandardError => e
            raise unless operation_failed

            # Warn because the session-level override may remain in effect
            # if the connection survives.
            warn "[strong_migrations] Failed to restore lock_timeout: #{e.message}" unless local
          end
        end
      end

      def check_lock_timeout(limit)
        # bypass the query cache since SET does not invalidate cached timeout reads
        lock_timeout = connection.uncached { select_all("SHOW lock_timeout") }.first["lock_timeout"]
        lock_timeout_sec = timeout_to_sec(lock_timeout)
        if lock_timeout_sec == 0
          warn "[strong_migrations] DANGER: No lock timeout set"
        elsif lock_timeout_sec > limit
          warn "[strong_migrations] DANGER: Lock timeout is longer than #{limit} seconds: #{lock_timeout}"
        end
      end

      def analyze_table(table)
        connection.execute "ANALYZE #{connection.quote_table_name(table.to_s)}"
      end

      def add_column_default_safe?
        true
      end

      def change_type_safe?(table, column, type, options, existing_column, existing_type)
        safe = false

        case type.to_s
        when "string"
          # safe to increase limit or remove it
          # not safe to decrease limit or add a limit
          case existing_type
          when "character varying"
            safe = !options[:limit] || (existing_column.limit && options[:limit] >= existing_column.limit)
          when "text"
            safe = !options[:limit]
          when "citext"
            safe = !options[:limit] && !indexed?(table, column)
          end
        when "text"
          # safe to change varchar to text (and text to text)
          safe =
            ["character varying", "text"].include?(existing_type) ||
            (existing_type == "citext" && !indexed?(table, column))
        when "citext"
          safe = ["character varying", "text"].include?(existing_type) && !indexed?(table, column)
        when "varbit"
          # increasing length limit or removing the limit is safe
          # but there doesn't seem to be a way to set/modify it
          # https://wiki.postgresql.org/wiki/What%27s_new_in_PostgreSQL_9.2#Reduce_ALTER_TABLE_rewrites
        when "numeric", "decimal"
          # numeric and decimal are equivalent and can be used interchangeably
          safe = ["numeric", "decimal"].include?(existing_type) &&
            (
              (
                # unconstrained
                !options[:precision] && !options[:scale]
              ) || (
                # increased precision, same scale
                options[:precision] && existing_column.precision &&
                options[:precision] >= existing_column.precision &&
                options[:scale] == existing_column.scale
              )
            )
        when "datetime", "timestamp", "timestamptz"
          # precision for datetime
          # limit for timestamp, timestamptz
          precision = (type.to_s == "datetime" ? options[:precision] : options[:limit]) || 6
          existing_precision = existing_column.limit || existing_column.precision || 6

          type_map = {
            "timestamp" => "timestamp without time zone",
            "timestamptz" => "timestamp with time zone"
          }
          maybe_safe = type_map.value?(existing_type) && precision >= existing_precision

          if maybe_safe
            new_type = type.to_s == "datetime" ? datetime_type : type.to_s

            # resolve with fallback
            new_type = type_map[new_type] || new_type

            safe = new_type == existing_type || time_zone == "UTC"
          end
        when "time"
          precision = options[:precision] || options[:limit] || 6
          existing_precision = existing_column.precision || existing_column.limit || 6

          safe = existing_type == "time without time zone" && precision >= existing_precision
        when "timetz"
          # increasing precision is safe
          # but there doesn't seem to be a way to set/modify it
        when "interval"
          # https://wiki.postgresql.org/wiki/What%27s_new_in_PostgreSQL_9.2#Reduce_ALTER_TABLE_rewrites
          # Active Record uses precision before limit
          precision = options[:precision] || options[:limit] || 6
          existing_precision = existing_column.precision || existing_column.limit || 6

          safe = existing_type == "interval" && precision >= existing_precision
        when "inet"
          safe = existing_type == "cidr"
        end

        safe
      end

      def writes_blocked?
        query = <<~SQL
          SELECT
            relation::regclass::text
          FROM
            pg_locks
          WHERE
            mode IN ('ShareRowExclusiveLock', 'AccessExclusiveLock') AND
            pid = pg_backend_pid()
        SQL
        select_all(query.squish).any?
      end

      # Report whether this session holds locks that can block application queries.
      def application_blocking_lock_held?
        # only allow relation locks that cannot block application reads or writes
        # RowExclusiveLock and RowShareLock can indicate row locks held by writes
        # or locking reads, even when the relation lock itself does not block queries
        # foreign key validation also holds RowShareLock until the transaction ends
        # only check granted relation locks, not locks on the transaction's own ID
        query = <<~SQL
          SELECT
            1
          FROM
            pg_locks
          WHERE
            locktype = 'relation' AND
            mode NOT IN ('AccessShareLock', 'ShareUpdateExclusiveLock') AND
            pid = pg_backend_pid() AND
            granted
          LIMIT 1
        SQL
        # bypass the query cache since locking reads do not clear cached lock state
        connection.uncached { select_all(query.squish) }.any?
      end

      # only check in non-developer environments (where actual server version is used)
      def index_corruption?
        server_version >= Gem::Version.new("14.0") &&
          server_version < Gem::Version.new("14.4") &&
          !StrongMigrations.developer_env?
      end

      # default to true if unsure
      def default_volatile?(default)
        name = default.to_s.delete_suffix("()")
        rows = select_all("SELECT provolatile FROM pg_proc WHERE proname = #{connection.quote(name)}").to_a
        rows.empty? || rows.any? { |r| r["provolatile"] == "v" }
      end

      def auto_incrementing_types
        ["primary_key", "serial", "bigserial"]
      end

      def max_constraint_name_length
        63
      end

      def constraints(table, column)
        # TODO improve column check
        connection.check_constraints(table).select { |c| /\b#{Regexp.escape(column.to_s)}\b/.match?(c.expression) }
      end

      # returns pg_constraint.contype, or nil if the constraint or table does not exist
      def constraint_type(table, name)
        # to_regclass returns NULL instead of raising for a name that does not resolve -
        # an eligibility check must never be what breaks a migration
        query = <<~SQL
          SELECT contype
          FROM pg_constraint
          WHERE conrelid = to_regclass(#{connection.quote(connection.quote_table_name(table.to_s))})
            AND conname = #{connection.quote(name.to_s)}
        SQL
        # bypass the query cache so each statement checks the current constraint type
        connection.uncached { select_all(query.squish) }.first&.fetch("contype")
      end

      # The name distinguishes the server's state from the Active Record
      # count checked by SafeMethods#in_transaction?; Checker uses both methods.
      def server_in_transaction?
        # Query the server because direct BEGIN and COMMIT calls leave Active
        # Record's transaction count unchanged. SafeMethods#disable_transaction
        # commits the DDL transaction, then safe_change_column_null starts a new
        # transaction with begin_db_transaction. The count stays at 1 even while
        # the server is between transactions.
        #
        # Subtracting the committed transaction from the count would also hide
        # the new transaction. After a lock timeout, a statement retry would then
        # fail with PG::InFailedSqlTransaction. An accurate count would need to
        # track every direct BEGIN and COMMIT issued by the gem.
        #
        # raw_connection marks the connection dirty and disables lazy
        # transactions. This prevents automatic verification and reconnection
        # with state restoration until the next checkout. Use the public method
        # despite these side effects to avoid depending on @raw_connection.
        raw = connection.raw_connection
        if raw.respond_to?(:transaction_status)
          # Only INTRANS and INERROR identify a transaction block. ACTIVE means
          # a command is running; UNKNOWN means the connection is invalid.
          # Treating either as a transaction could select SET LOCAL outside a
          # transaction, where Postgres ignores it.
          IN_TRANSACTION_STATUSES.include?(raw.transaction_status)
        else
          # Fall back to Active Record when the driver cannot report transaction
          # status, as with JDBC. After a direct COMMIT, the stale count can
          # cause us to use SET LOCAL outside a transaction, where the server
          # ignores the timeout override. Keep this conservative fallback:
          # reporting no transaction could allow statement retries inside
          # safe_change_column_null's aborted transaction and fail the migration.
          connection.open_transactions > 0
        end
      end

      private

      def set_timeout(setting, timeout, local: false)
        # use ceil to prevent no timeout for values under 1 ms
        timeout = (timeout.to_f * 1000).ceil unless timeout.is_a?(String)

        scope = local ? "LOCAL" : nil
        sql = ["SET", scope, "#{setting} TO #{connection.quote(timeout)}"].compact.join(" ")

        # bypass the query cache so every SET reaches the server
        connection.uncached { select_all(sql) }
      end

      # units: https://www.postgresql.org/docs/current/config-setting.html
      def timeout_to_sec(timeout)
        units = {
          "us" => 0.001,
          "ms" => 1,
          "s" => 1000,
          "min" => 1000 * 60,
          "h" => 1000 * 60 * 60,
          "d" => 1000 * 60 * 60 * 24
        }
        timeout_ms = timeout.to_i
        units.each do |k, v|
          if timeout.end_with?(k)
            timeout_ms *= v
            break
          end
        end
        timeout_ms / 1000.0
      end

      # columns is array for column index and string for expression index
      # the current approach can yield false positives for expression indexes
      # but prefer to keep it simple for now
      def indexed?(table, column)
        connection.indexes(table).any? { |i| i.columns.include?(column.to_s) }
      end

      def datetime_type
        # https://github.com/rails/rails/pull/41084
        # no need to support custom datetime_types
        key = connection.class.datetime_type

        # could be timestamp, timestamp without time zone, timestamp with time zone, etc
        connection.class.const_get(:NATIVE_DATABASE_TYPES).fetch(key).fetch(:name)
      end

      # do not memoize
      # want latest value
      def time_zone
        select_all("SHOW timezone").first["TimeZone"]
      end
    end
  end
end
