require_relative "test_helper"

class TimeoutsTest < Minitest::Test
  # use multiples of this timeout for lock release delays and test deadlines
  NORMAL_LOCK_TIMEOUT = 0.1

  def teardown
    reset_timeouts
  end

  def test_timeouts
    skip unless postgresql? || mysql? || mariadb?

    StrongMigrations.statement_timeout = 1.hour
    StrongMigrations.transaction_timeout = 2.hours
    StrongMigrations.lock_timeout = 10.seconds

    migrate CheckTimeouts

    if postgresql?
      assert_equal "1h", $statement_timeout
      assert_equal "2h", $transaction_timeout if transaction_timeout?
      assert_equal "10s", $lock_timeout
    else
      assert_equal 3600, $statement_timeout
      assert_equal 10, $lock_timeout
    end
  end

  def test_statement_timeout_float
    skip unless postgresql? || mysql? || mariadb?

    StrongMigrations.statement_timeout = 0.5.seconds

    migrate CheckTimeouts

    if postgresql?
      assert_equal "500ms", $statement_timeout
    else
      assert_equal 0.5, $statement_timeout
    end
  end

  # designed for 0 case to prevent no timeout
  # but can't test without statement timeout error
  def test_statement_timeout_float_ceil
    skip unless postgresql? || mysql?

    StrongMigrations.statement_timeout = 1.000001.seconds

    migrate CheckTimeouts

    if postgresql?
      assert_equal "1001ms", $statement_timeout
    else
      assert_equal 1.001, $statement_timeout
    end
  end

  def test_transaction_timeout_float
    skip unless transaction_timeout?

    StrongMigrations.transaction_timeout = 0.5.seconds

    migrate CheckTimeouts

    assert_equal "500ms", $transaction_timeout
  end

  # designed for 0 case to prevent no timeout
  # but can't test without transaction timeout error
  def test_transaction_timeout_float_ceil
    skip unless transaction_timeout?

    StrongMigrations.transaction_timeout = 1.000001.seconds

    migrate CheckTimeouts

    assert_equal "1001ms", $transaction_timeout
  end

  def test_transaction_timeout_is_set_before_statements
    skip unless transaction_timeout?

    StrongMigrations.transaction_timeout = 1.seconds

    migrate CheckTransactionTimeoutWithoutStatement

    assert_equal "1s", $transaction_timeout
  end

  def test_lock_timeout_float
    skip unless postgresql?

    StrongMigrations.lock_timeout = 0.5.seconds

    migrate CheckTimeouts

    assert_equal "500ms", $lock_timeout
  end

  def test_timeouts_string
    skip unless postgresql?

    StrongMigrations.statement_timeout = "1h"
    StrongMigrations.transaction_timeout = "2h"
    StrongMigrations.lock_timeout = "1d"

    migrate CheckTimeouts

    assert_equal "1h", $statement_timeout
    assert_equal "2h", $transaction_timeout if transaction_timeout?
    assert_equal "1d", $lock_timeout
  end

  def test_lock_timeout_limit
    StrongMigrations.lock_timeout_limit = 10.seconds
    StrongMigrations.lock_timeout = 20.seconds

    assert_output(nil, /Lock timeout is longer than 10 seconds/) do
      migrate CheckLockTimeout
    end
  ensure
    StrongMigrations.lock_timeout_limit = nil
  end

  def test_lock_timeout_limit_postgresql
    skip unless postgresql?

    StrongMigrations.lock_timeout_limit = 10.seconds

    # no warning
    ActiveRecord::Base.connection.execute("SET lock_timeout = '100ms'")
    _, stderr = capture_io do
      migrate CheckLockTimeout
    end
    refute_match(/Lock timeout is longer than 10 seconds/, stderr)

    # warning
    ["1min", "1h", "1d"].each do |timeout|
      ActiveRecord::Base.connection.execute("SET lock_timeout = '#{timeout}'")
      assert_output(nil, /Lock timeout is longer than 10 seconds/) do
        migrate CheckLockTimeout
      end
    end
  ensure
    StrongMigrations.lock_timeout_limit = nil
  end

  def test_lock_timeout_retries
    assert_retries CheckLockTimeoutRetries

    # MySQL and MariaDB do not support DDL transactions
    assert_equal (postgresql? ? 3 : 1), $migrate_attempts
  end

  def test_lock_timeout_retries_no_retries
    with_lock_timeout_retries(lock: false) do
      assert_safe CheckLockTimeoutRetries
      # up and down
      assert_equal 2, $migrate_attempts
    end
  end

  def test_lock_timeout_retries_transaction
    refute_retries CheckLockTimeoutRetriesTransaction

    # does not retry
    assert_equal 1, $migrate_attempts
    assert_equal 1, $transaction_attempts
  end

  def test_lock_timeout_retries_transaction_ddl_transaction
    skip "Requires DDL transaction" unless postgresql?

    assert_retries CheckLockTimeoutRetriesTransactionDdlTransaction

    # retries entire migration, not transaction block alone
    assert_equal 3, $migrate_attempts
    assert_equal 3, $transaction_attempts
  end

  def test_lock_timeout_retries_no_ddl_transaction
    assert_retries CheckLockTimeoutRetriesNoDdlTransaction

    # retries only single statement, not migration
    assert_equal 1, $migrate_attempts
  end

  def test_lock_timeout_retries_commit_db_transaction
    skip "Requires DDL transaction" unless postgresql?

    refute_retries CheckLockTimeoutRetriesCommitDbTransaction

    # does not retry since outside DDL transaction
    assert_equal 1, $migrate_attempts
  end

  def test_lock_timeout_retries_add_index
    skip unless postgresql?

    error = assert_raises(ActiveRecord::StatementInvalid) do
      with_lock_timeout_retries do
        migrate AddIndexConcurrently
      end
    end
    assert_kind_of PG::DuplicateTable, error.cause

    migrate AddIndexConcurrently, direction: :down
  end

  def test_lock_timeout_retries_add_index_remove_invalid_indexes
    skip unless postgresql?

    with_option(:remove_invalid_indexes, true) do
      assert_retries AddIndexConcurrently
    end

    migrate AddIndexConcurrently, direction: :down
  end

  def test_lock_timeout_retries_analyze
    skip unless postgresql?

    statements = nil
    with_auto_analyze do
      with_analyze_failures(1) do
        with_lock_timeout_retries(lock: false) do
          statements = capture_statements do
            migrate AddIndexConcurrently
          end
        end
      end
    end

    assert_equal 2, $analyze_attempts
    assert_equal 1, statements.count { |s| s.start_with?("CREATE INDEX") }
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # test_lock_timeout_retries_analyze injects the LockWaitTimeout, which only
  # proves where the retry block sits, not that a real timeout (with the
  # aborted-transaction state Postgres leaves behind) is handled correctly -
  # this is the non-transactional path: a disable_ddl_transaction! migration,
  # so only the ANALYZE statement itself is retried, not the index build
  def test_lock_timeout_retries_analyze_real_lock_no_ddl_transaction
    skip unless postgresql?

    migration = AddIndexConcurrently.new
    statements = nil
    retries = nil
    with_auto_analyze do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          # SHARE UPDATE EXCLUSIVE permits the concurrent build (nothing conflicts
          # with it yet) but blocks the ANALYZE that follows - acquire the lock only
          # once that real ANALYZE is about to run, since the build needs the same
          # lock level and taking it any earlier would block the build too
          retries =
            with_lock_released_on_retry(migration, "users", mode: "SHARE UPDATE EXCLUSIVE", defer_until_analyze: true) do
              statements = capture_statements do
                migrate migration
              end
            end
        end
      end
    end

    assert_equal 1, retries
    assert_equal 1, statements.count { |s| s.start_with?("CREATE INDEX") }
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # same gap as above, for the DDL-transaction path: an ordinary transactional
  # migration, so a real ANALYZE timeout rolls back and replays the whole
  # transaction, unlike the non-transactional path above where only the
  # ANALYZE statement is retried
  def test_lock_timeout_retries_analyze_real_lock_ddl_transaction
    skip unless postgresql?

    migration = AddIndexNonConcurrentlyWithAutoAnalyze.new
    statements = nil
    retries = nil
    with_auto_analyze do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          # SHARE permits the (non-concurrent) index build, since it does not
          # conflict with another session's SHARE lock, but blocks the ANALYZE that
          # follows, which needs SHARE UPDATE EXCLUSIVE - the lock can be taken up
          # front here, since it never conflicts with the build
          retries =
            with_lock_released_on_retry(migration, "users", mode: "SHARE") do
              statements = capture_statements do
                migrate migration
              end
            end
        end
      end
    end

    assert_equal 1, retries
    # the whole transaction is rolled back and replayed, so unlike the
    # non-transactional path, the index build itself is attempted twice
    assert_equal 2, statements.count { |s| s.start_with?("CREATE INDEX") }
  ensure
    migrate AddIndexNonConcurrentlyWithAutoAnalyze, direction: :down if postgresql?
  end

  # safe_by_default commits without updating Active Record's transaction count
  # retry only ANALYZE, since retrying the index build raises PG::DuplicateTable

  def test_non_blocking_lock_timeout_add_index
    skip unless postgresql?

    said = []
    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        # the concurrent build waits for the transaction holding ROW EXCLUSIVE
        with_lock_released_on_contention("users", outlast: NORMAL_LOCK_TIMEOUT * 5) do
          migration = AddIndexConcurrently.new
          original_say = migration.method(:say)
          migration.define_singleton_method(:say, proc { |message, *args, **options|
            said << message
            original_say.call(message, *args, **options)
          })
          migrate migration
        end
      end
    end

    refute(said.any? { |message| message.include?("Lock timeout") })
    assert index_valid?("index_users_on_name")
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # safe_by_default commits without updating Active Record's transaction count
  # use a session SET since Postgres ignores SET LOCAL outside a transaction
  def test_non_blocking_lock_timeout_add_index_safe_by_default
    skip unless postgresql?

    statements = nil
    with_option(:safe_by_default, true) do
      with_option(:non_blocking_lock_timeout, 0) do
        statements = capture_statements do
          migrate AddIndexSafeByDefault
        end
      end
    end

    build_index = statements.index { |s| s.start_with?("CREATE INDEX") }
    refute_nil build_index, "expected the CONCURRENTLY build to run"

    set_before_build = statements[0...build_index].reverse.find { |s| s.match?(/\ASET\s+(LOCAL\s+)?lock_timeout/i) }
    refute_nil set_before_build, "expected a SET lock_timeout before the build"

    refute_match(/\ASET LOCAL/i, set_before_build, "override must be a session SET, not SET LOCAL")
  ensure
    migrate AddIndexSafeByDefault, direction: :down if postgresql?
  end

  def test_non_blocking_lock_timeout_restores_lock_timeout
    skip unless postgresql?

    StrongMigrations.lock_timeout = 5.seconds
    with_option(:non_blocking_lock_timeout, 0) do
      migrate CheckLockTimeoutAfterConcurrentIndex
    end

    assert_equal "5s", $lock_timeout_after
  ensure
    migrate CheckLockTimeoutAfterConcurrentIndex, direction: :down if postgresql?
  end

  # foreign key validation must use the normal timeout even without prior locks
  def test_non_blocking_lock_timeout_validate_foreign_key
    skip unless postgresql?

    add_not_valid_foreign_key

    # leave retries disabled so the observer records a single attempt
    with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
      with_option(:non_blocking_lock_timeout, 0) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          _, observations =
            with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
              observe_validate_constraint_lock_timeout_during do
                assert_raises(ActiveRecord::LockWaitTimeout) { migrate(ValidateForeignKeyOnly) }
              end
            end

          assert_equal ["100ms"], observations
        end
      end
    end
  ensure
    remove_not_valid_foreign_key if postgresql?
  end

  def test_non_blocking_lock_timeout_validate_check_constraint
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_only", validate: false

    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        # SHARE UPDATE EXCLUSIVE conflicts with itself
        # hold the lock past the normal timeout to verify the override
        result, observations =
          with_lock_released_on_contention("users", mode: "SHARE UPDATE EXCLUSIVE", outlast: NORMAL_LOCK_TIMEOUT * 5) do
            observe_validate_constraint_lock_timeout_during { migrate(ValidateCheckConstraintOnly) }
          end
        assert result

        assert_equal ["0"], observations

        assert_equal "100ms", connection.select_all("SHOW lock_timeout").first["lock_timeout"]
      end
    end
  ensure
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :users, name: "credit_check_only", if_exists: true if postgresql?
  end

  def test_non_blocking_lock_timeout_keeps_error_in_transaction
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.execute("INSERT INTO users (credit_score) VALUES (-1)")
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check", validate: false

    # use a normal timeout distinct from the override to detect a missing override
    error, observations =
      with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
        with_option(:non_blocking_lock_timeout, 0) do
          observe_validate_constraint_lock_timeout_during do
            assert_raises(ActiveRecord::StatementInvalid) do
              migrate ValidateCheckConstraintInTransaction
            end
          end
        end
      end

    # restoring the timeout must not replace the error with PG::InFailedSqlTransaction
    assert_kind_of PG::CheckViolation, error.cause

    assert_equal ["0"], observations
  ensure
    if postgresql?
      connection = ActiveRecord::Base.connection
      connection.execute("DELETE FROM users WHERE credit_score = -1")
      connection.remove_check_constraint :users, name: "credit_check", if_exists: true
    end
  end

  # restoring a SET LOCAL value with a session SET would preserve it after commit
  def test_non_blocking_lock_timeout_transaction_commit_does_not_promote_local_timeout
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '5s'")
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_local_timeout", validate: false

    result, observations =
      with_option(:non_blocking_lock_timeout, 0) do
        observe_validate_constraint_lock_timeout_during { migrate(ValidateCheckConstraintWithLocalLockTimeout) }
      end
    assert result

    assert_equal ["0"], observations

    assert_equal "5s", connection.select_all("SHOW lock_timeout").first["lock_timeout"]
  ensure
    if postgresql?
      ActiveRecord::Base.connection.remove_check_constraint :users, name: "credit_check_local_timeout", if_exists: true
    end
  end

  # dropping the invalid index nests a timeout override inside the build's override
  # cached SHOW or SET statements could restore the wrong timeout
  def test_non_blocking_lock_timeout_add_index_remove_invalid_indexes_query_cache
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.execute("INSERT INTO users (name) VALUES ('dup_check'), ('dup_check')")

    StrongMigrations.lock_timeout = 10.seconds
    assert_raises(ActiveRecord::RecordNotUnique) do
      migrate AddUniqueIndexConcurrentlyDupCheck
    end
    refute index_valid?("index_users_on_name_dup_check")

    connection.execute("DELETE FROM users WHERE name = 'dup_check'")

    statements =
      with_option(:remove_invalid_indexes, true) do
        with_option(:non_blocking_lock_timeout, 0) do
          connection.cache do
            capture_statements do
              migrate AddUniqueIndexConcurrentlyDupCheck
            end
          end
        end
      end

    build_index = statements.index { |s| s.start_with?("CREATE") && s.include?("index_users_on_name_dup_check") }
    refute_nil build_index, "expected the outer CREATE INDEX CONCURRENTLY to run"

    last_lock_timeout_set = statements[0...build_index].reverse.find { |s| s.match?(/\ASET\s+(LOCAL\s+)?lock_timeout/) }
    refute_nil last_lock_timeout_set, "expected a SET lock_timeout before the outer build"

    # both an integer override and a quoted restore must keep the timeout at 0
    value = last_lock_timeout_set.sub(/\A.*TO\s+/, "").delete("'")
    assert_equal "0", value
  ensure
    if postgresql?
      connection = ActiveRecord::Base.connection
      if connection.index_exists?(:users, :name, name: "index_users_on_name_dup_check")
        migrate AddUniqueIndexConcurrentlyDupCheck, direction: :down
      end
      connection.execute("DELETE FROM users WHERE name = 'dup_check'")
    end
  end

  def test_validate_foreign_key_without_option
    skip unless postgresql?

    add_not_valid_foreign_key

    assert_raises(ActiveRecord::LockWaitTimeout) do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
            migrate ValidateForeignKeyOnly
          end
        end
      end
    end
  ensure
    remove_not_valid_foreign_key if postgresql?
  end

  # LOCK ... IN ACCESS EXCLUSIVE MODE holds that lock until the transaction ends
  def test_non_blocking_lock_timeout_does_not_apply_after_access_exclusive_lock
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    # validate a check constraint (not a foreign key) so application_blocking_lock_held?,
    # not the unconditional foreign-key exclusion, is what denies the override
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_access_exclusive_lock", validate: false

    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          # EXCLUSIVE conflicts with the SHARE UPDATE EXCLUSIVE lock needed to validate the check constraint
          with_locked_table("users", mode: "EXCLUSIVE") do
            assert_raises(ActiveRecord::LockWaitTimeout) do
              migrate LockDevicesAccessExclusiveModeThenValidateConstraint
            end
          end
        end
      end
    end
  ensure
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :users, name: "credit_check_access_exclusive_lock", if_exists: true if postgresql?
  end

  # validate_constraint must also exclude foreign keys named directly
  def test_non_blocking_lock_timeout_validate_constraint_by_name
    skip unless postgresql?

    add_not_valid_foreign_key(name: "review_fk")

    # leave retries disabled so the observer records a single attempt
    with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
      with_option(:non_blocking_lock_timeout, 0) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          _, observations =
            with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
              observe_validate_constraint_lock_timeout_during do
                assert_raises(ActiveRecord::LockWaitTimeout) { migrate(ValidateConstraintOnly) }
              end
            end

          assert_equal ["100ms"], observations
        end
      end
    end
  ensure
    remove_not_valid_foreign_key if postgresql?
  end

  # Postgres 18 supports NOT VALID for NOT NULL constraints. Validating them
  # takes ACCESS EXCLUSIVE, which blocks reads and writes, so they must keep
  # the normal lock timeout.
  def test_non_blocking_lock_timeout_validate_constraint_not_null
    skip unless postgresql?
    skip if postgresql_version < 18

    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE users ADD CONSTRAINT city_not_null_check NOT NULL city NOT VALID")

    with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
      with_option(:non_blocking_lock_timeout, 0) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          _, observations =
            with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
              observe_validate_constraint_lock_timeout_during do
                assert_raises(ActiveRecord::LockWaitTimeout) { migrate(ValidateConstraintNotNullOnly) }
              end
            end

          assert_equal ["100ms"], observations
        end
      end
    end
  ensure
    if postgresql?
      ActiveRecord::Base.connection.execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS city_not_null_check")
    end
  end

  # The timeout override for validate_check_constraint relies on Active Record
  # returning only check constraints. NOT NULL constraints must be excluded:
  # validating them on Postgres 18 requires an ACCESS EXCLUSIVE lock.
  def test_check_constraints_excludes_not_null_constraints
    skip unless postgresql?
    skip if postgresql_version < 18

    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE users ADD CONSTRAINT city_not_null_canary NOT NULL city NOT VALID")

    names = connection.check_constraints("users").map(&:name)

    refute_includes names, "city_not_null_canary",
      "validate_check_constraint can now reach a constraint that needs ACCESS EXCLUSIVE"
  ensure
    if postgresql?
      ActiveRecord::Base.connection.execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS city_not_null_canary")
    end
  end

  def test_non_blocking_lock_timeout_validate_constraint_naming_check_constraint
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_by_name", validate: false

    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        # SHARE UPDATE EXCLUSIVE conflicts with itself
        # hold the lock past the normal timeout to verify the override
        result, observations =
          with_lock_released_on_contention("users", mode: "SHARE UPDATE EXCLUSIVE", outlast: NORMAL_LOCK_TIMEOUT * 5) do
            observe_validate_constraint_lock_timeout_during { migrate(ValidateConstraintCheckConstraintOnly) }
          end
        assert result

        assert_equal ["0"], observations

        assert_equal "100ms", connection.select_all("SHOW lock_timeout").first["lock_timeout"]
      end
    end
  ensure
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :users, name: "credit_check_by_name", if_exists: true if postgresql?
  end

  # the checker must resolve table_name_prefix the same way Rails will,
  # before asking the database about the constraint - otherwise the lookup
  # targets a table that does not exist
  def test_non_blocking_lock_timeout_validate_constraint_with_table_name_prefix
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.create_table "scratch_items", force: true do |t|
      t.integer :amount
    end
    connection.add_check_constraint "scratch_items", "amount > 0", name: "predicate_check", validate: false

    result, observations =
      with_table_name_prefix("scratch_") do
        with_option(:non_blocking_lock_timeout, 0) do
          observe_validate_constraint_lock_timeout_during { migrate_instance(ValidateConstraintByTableName) }
        end
      end

    assert result
    assert_equal ["0"], observations
  ensure
    ActiveRecord::Base.connection.drop_table "scratch_items", if_exists: true if postgresql?
  end

  # same as above, for table_name_suffix
  def test_non_blocking_lock_timeout_validate_constraint_with_table_name_suffix
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.create_table "items_scratch", force: true do |t|
      t.integer :amount
    end
    connection.add_check_constraint "items_scratch", "amount > 0", name: "predicate_check", validate: false

    result, observations =
      with_table_name_suffix("_scratch") do
        with_option(:non_blocking_lock_timeout, 0) do
          observe_validate_constraint_lock_timeout_during { migrate_instance(ValidateConstraintByTableName) }
        end
      end

    assert result
    assert_equal ["0"], observations
  ensure
    ActiveRecord::Base.connection.drop_table "items_scratch", if_exists: true if postgresql?
  end

  # proper_table_name resolves a model class via its own table_name method,
  # skipping the prefix/suffix branch entirely
  def test_non_blocking_lock_timeout_validate_constraint_with_model_class_table_name
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.create_table "custom_named_items", force: true do |t|
      t.integer :amount
    end
    connection.add_check_constraint "custom_named_items", "amount > 0", name: "predicate_check", validate: false

    result, observations =
      with_option(:non_blocking_lock_timeout, 0) do
        observe_validate_constraint_lock_timeout_during { migrate(ValidateConstraintByModelClass) }
      end

    assert result
    assert_equal ["0"], observations
  ensure
    ActiveRecord::Base.connection.drop_table "custom_named_items", if_exists: true if postgresql?
  end

  # a lookup against the wrong (unresolved) table would find a different
  # constraint under the same name and misclassify eligibility, rather than
  # simply fail - prove the resolved table is the one actually queried
  def test_non_blocking_lock_timeout_validate_constraint_resolves_correct_table
    skip unless postgresql?

    connection = ActiveRecord::Base.connection

    # unresolved name: a same-named constraint of a different kind
    connection.create_table "items", force: true do |t|
      t.bigint :order_id
    end
    connection.add_foreign_key "items", :orders, column: "order_id", name: "predicate_check", validate: false

    # resolved name: the constraint that should actually be classified
    connection.create_table "dual_items", force: true do |t|
      t.integer :amount
    end
    connection.add_check_constraint "dual_items", "amount > 0", name: "predicate_check", validate: false

    result, observations =
      with_table_name_prefix("dual_") do
        with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
          with_option(:non_blocking_lock_timeout, 0) do
            observe_validate_constraint_lock_timeout_during { migrate_instance(ValidateConstraintByTableName) }
          end
        end
      end

    assert result
    # "0" (the override) proves the resolved table's check constraint was
    # used; the unresolved table's foreign key would have excluded it and
    # left the normal "100ms" timeout in place
    assert_equal ["0"], observations
  ensure
    if postgresql?
      connection = ActiveRecord::Base.connection
      connection.drop_table "items", if_exists: true
      connection.drop_table "dual_items", if_exists: true
    end
  end

  # verify numeric seconds with the query cache enabled
  def test_non_blocking_lock_timeout_remove_index_finite_value
    skip unless postgresql?

    migrate AddIndexConcurrently

    connection = ActiveRecord::Base.connection
    before = connection.select_all("SHOW lock_timeout").first["lock_timeout"]

    statements, observations =
      with_option(:non_blocking_lock_timeout, 0.25) do
        connection.cache do
          observe_lock_timeout_during do
            capture_statements do
              migrate RemoveIndexConcurrently
            end
          end
        end
      end

    drop_index = statements.index { |s| s.start_with?("DROP INDEX") }
    refute_nil drop_index, "expected the CONCURRENTLY drop to run"

    assert_equal ["250ms"], observations, "expected the server's lock_timeout to be 250ms during the drop"

    after = connection.select_all("SHOW lock_timeout").first["lock_timeout"]
    assert_equal before, after, "expected lock_timeout to be restored to its previous value on the server"
  ensure
    ActiveRecord::Base.connection.remove_index :users, :name, if_exists: true if postgresql?
  end

  # verify a Postgres duration string for both the index build and ANALYZE
  def test_non_blocking_lock_timeout_analyze_duration_string_value
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    before = connection.select_all("SHOW lock_timeout").first["lock_timeout"]

    statements, observations = nil
    with_option(:non_blocking_lock_timeout, "2s") do
      with_auto_analyze do
        statements, observations = observe_lock_timeout_during do
          capture_statements do
            migrate AddIndexConcurrently
          end
        end
      end
    end

    analyze_index = statements.index { |s| s.start_with?("ANALYZE") }
    refute_nil analyze_index, "expected the ANALYZE to run"

    assert_equal ["2s", "2s"], observations, "expected the server's lock_timeout to be 2s for both the build and the ANALYZE"

    after = connection.select_all("SHOW lock_timeout").first["lock_timeout"]
    assert_equal before, after, "expected lock_timeout to be restored to its previous value on the server"
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # exhausting ANALYZE retries must leave the successful index build intact
  def test_non_blocking_lock_timeout_analyze_retries_exhausted
    skip unless postgresql?

    statements = nil
    with_option(:non_blocking_lock_timeout, 0) do
      with_auto_analyze do
        with_analyze_failures(10) do
          with_lock_timeout_retries(lock: false) do
            statements = capture_statements do
              assert_raises(ActiveRecord::LockWaitTimeout) do
                migrate AddIndexConcurrently
              end
            end
          end
        end
      end
    end

    # one initial attempt and two retries
    assert_equal 3, $analyze_attempts
    assert_equal 1, statements.count { |s| s.start_with?("CREATE INDEX") }
    assert index_valid?("index_users_on_name")
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # a missing column makes CREATE INDEX fail without aborting a transaction
  # the session timeout must still be restored
  def test_non_blocking_lock_timeout_restores_after_non_transactional_error
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    before = connection.select_all("SHOW lock_timeout").first["lock_timeout"]

    with_option(:non_blocking_lock_timeout, 0) do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        migrate AddIndexConcurrentlyMissingColumn
      end
      assert_kind_of PG::UndefinedColumn, error.cause
    end

    assert_equal before, connection.select_all("SHOW lock_timeout").first["lock_timeout"]
  end

  # add_reference keeps its normal timeout because adding the column blocks writes
  # the ANALYZE after add_reference can use the override
  def test_non_blocking_lock_timeout_add_reference_concurrently_exception
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    before = connection.select_all("SHOW lock_timeout").first["lock_timeout"]

    statements, observations = nil
    with_option(:non_blocking_lock_timeout, 0.3) do
      with_auto_analyze do
        statements, observations = observe_lock_timeout_during do
          capture_statements do
            migrate AddReferenceConcurrently
          end
        end
      end
    end

    create_index = statements.index { |s| s.start_with?("CREATE INDEX") }
    analyze_index = statements.index { |s| s.start_with?("ANALYZE") }
    refute_nil create_index, "expected the concurrent index build to run"
    refute_nil analyze_index, "expected the ANALYZE to run"

    refute(
      statements[0..create_index].any? { |s| s.match?(/\ASET\s+lock_timeout/i) },
      "expected no lock_timeout override around the column add or its index"
    )

    assert_equal ["300ms"], observations, "expected the server's lock_timeout to be 300ms during the ANALYZE"

    after = connection.select_all("SHOW lock_timeout").first["lock_timeout"]
    assert_equal before, after, "expected lock_timeout to be restored to its previous value on the server"
  ensure
    migrate AddReferenceConcurrently, direction: :down if postgresql?
  end

  # Reverting a change migration records each command, then executes its inverse.
  # Recording executes no SQL for the command and needs no timeout override.
  def test_non_blocking_lock_timeout_skips_the_recording_pass
    skip unless postgresql?

    migrate AddIndexConcurrently

    statements = nil
    with_option(:non_blocking_lock_timeout, 0.25) do
      statements = capture_statements do
        migrate AddIndexConcurrently, direction: :down
      end
    end

    assert_equal 1, statements.count { |s| s.start_with?("DROP INDEX") }
    assert_equal 2, statements.count { |s| s.start_with?("SET lock_timeout") },
      "expected one timeout override and one restore during replay only"
    assert_equal 1, statements.count { |s| s.include?("pg_locks") }
  ensure
    ActiveRecord::Base.connection.remove_index :users, :name, if_exists: true if postgresql?
  end

  # auto_analyze must also skip timeout overrides while recording commands.
  def test_non_blocking_lock_timeout_analyze_skips_the_recording_pass
    skip unless postgresql?

    migrate AddIndexConcurrently

    statements = nil
    with_option(:non_blocking_lock_timeout, 0.25) do
      with_auto_analyze do
        statements = capture_statements do
          # Active Record cannot reverse a recorded ANALYZE command. This error
          # is expected regardless of whether timeout overrides are skipped.
          assert_raises(ActiveRecord::IrreversibleMigration) do
            migrate RevertAddIndexConcurrently
          end
        end
      end
    end

    refute(statements.any? { |s| s.start_with?("SET lock_timeout") },
      "expected no timeout override while recording")
    refute(statements.any? { |s| s.include?("pg_locks") },
      "expected no lock probe while recording")
  ensure
    ActiveRecord::Base.connection.remove_index :users, :name, if_exists: true if postgresql?
  end

  # Custom checks can remove the options hash from the arguments array.
  def test_non_blocking_lock_timeout_survives_a_custom_check
    skip unless postgresql?

    StrongMigrations.add_check do |method, args|
      args.extract_options! if method == :add_index
    end

    statements = nil
    with_option(:non_blocking_lock_timeout, 0.25) do
      statements = capture_statements do
        migrate AddIndexConcurrently
      end
    end

    assert_equal 2, statements.count { |s| s.start_with?("SET lock_timeout") },
      "expected one timeout override and one restore"
  ensure
    if postgresql?
      StrongMigrations.checks.pop
      migrate AddIndexConcurrently, direction: :down
    end
  end

  # Rails resolves the table name before building the index. The checker must
  # resolve its own copy of the argument so ANALYZE targets the same table.
  def test_auto_analyze_resolves_table_name_prefix
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.create_table "scratch_items", force: true do |t|
      t.integer :amount
    end

    statements = nil
    with_table_name_prefix("scratch_") do
      with_auto_analyze do
        statements = capture_statements do
          migrate_instance(AddIndexConcurrentlyByTableName)
        end
      end
    end

    assert_includes statements, 'ANALYZE "scratch_items"'
  ensure
    ActiveRecord::Base.connection.drop_table "scratch_items", if_exists: true if postgresql?
  end

  # An enclosing rescue can leave $! set even when the wrapped block succeeds.
  # A failed restore must still raise, since the session keeps the override.
  def test_with_lock_timeout_raises_restore_failure_after_successful_block
    skip unless postgresql?

    adapter = adapter_for_current_connection
    original = adapter.method(:set_lock_timeout)
    calls = 0
    adapter.define_singleton_method(:set_lock_timeout) do |timeout, local: false|
      calls += 1
      raise "restore failed" if calls > 1
      original.call(timeout, local: local)
    end

    error =
      assert_raises(RuntimeError) do
        begin
          raise "unrelated outer error"
        rescue RuntimeError
          adapter.with_lock_timeout(0.25) { :ok }
        end
      end

    assert_equal "restore failed", error.message
  ensure
    ActiveRecord::Base.connection.execute("RESET lock_timeout") if postgresql?
  end

  # Rollback undoes the transaction-local override. Preserve the operation's
  # error if restoring the timeout also fails.
  def test_with_lock_timeout_prefers_the_blocks_error_over_a_restore_failure
    skip unless postgresql?

    adapter = adapter_for_current_connection
    original = adapter.method(:set_lock_timeout)
    calls = 0
    adapter.define_singleton_method(:set_lock_timeout) do |timeout, local: false|
      calls += 1
      raise "restore failed" if calls > 1
      original.call(timeout, local: local)
    end

    error =
      assert_raises(RuntimeError) do
        ActiveRecord::Base.connection.transaction do
          adapter.with_lock_timeout(0.25) { raise "operation failed" }
        end
      end

    assert_equal "operation failed", error.message
  ensure
    ActiveRecord::Base.connection.execute("RESET lock_timeout") if postgresql?
  end

  # If applying the override fails, skip both the operation and the restore.
  def test_with_lock_timeout_does_not_restore_a_failed_override
    skip unless postgresql?

    adapter = adapter_for_current_connection
    calls = 0
    adapter.define_singleton_method(:set_lock_timeout) do |timeout, local: false|
      calls += 1
      raise "override failed"
    end

    ran = false
    error =
      assert_raises(RuntimeError) do
        adapter.with_lock_timeout(0.25) { ran = true }
      end

    assert_equal "override failed", error.message
    assert_equal 1, calls, "expected no restore after a failed override"
    refute ran
  end

  # Warn if restoring a session-level timeout fails, but preserve the
  # operation's error so retry logic can still rescue LockWaitTimeout.
  def test_with_lock_timeout_warns_on_a_failed_session_restore
    skip unless postgresql?

    adapter = adapter_for_current_connection
    original = adapter.method(:set_lock_timeout)
    calls = 0
    adapter.define_singleton_method(:set_lock_timeout) do |timeout, local: false|
      calls += 1
      raise "restore failed" if calls > 1
      original.call(timeout, local: local)
    end

    error = nil
    _, stderr = capture_io do
      error =
        assert_raises(ActiveRecord::LockWaitTimeout) do
          adapter.with_lock_timeout(0.25) { raise ActiveRecord::LockWaitTimeout, "operation failed" }
        end
    end

    assert_equal "operation failed", error.message
    assert_match(/Failed to restore lock_timeout: restore failed/, stderr)
  ensure
    ActiveRecord::Base.connection.execute("RESET lock_timeout") if postgresql?
  end

  # PQTRANS_ACTIVE and PQTRANS_UNKNOWN do not identify transaction blocks.
  # Treating them as transactions could select SET LOCAL outside a transaction
  # and incorrectly disable lock timeout retries.
  def test_server_in_transaction_only_counts_transaction_blocks
    skip unless postgresql?

    expected = {
      PG::PQTRANS_IDLE => false,
      PG::PQTRANS_ACTIVE => false,
      PG::PQTRANS_INTRANS => true,
      PG::PQTRANS_INERROR => true,
      PG::PQTRANS_UNKNOWN => false
    }

    expected.each do |status, in_transaction|
      adapter = StrongMigrations::Adapters::PostgreSQLAdapter.new(FakeChecker.new(status))
      assert_equal in_transaction, adapter.server_in_transaction?, "unexpected transaction state for status #{status}"
    end
  end

  # Fall back to Active Record's transaction count when the driver cannot
  # report transaction status, as with JDBC.
  def test_server_in_transaction_falls_back_without_transaction_status
    skip unless postgresql?

    adapter = StrongMigrations::Adapters::PostgreSQLAdapter.new(FakeChecker.new(nil))
    refute adapter.server_in_transaction?

    adapter = StrongMigrations::Adapters::PostgreSQLAdapter.new(FakeChecker.new(nil, open_transactions: 1))
    assert adapter.server_in_transaction?
  end

  # Skip the lock query when the timeout override is unset. Its result is only
  # needed to decide whether the override is safe.
  def test_non_blocking_lock_timeout_analyze_skips_lock_probe_when_option_unset
    skip unless postgresql?

    statements = nil
    with_auto_analyze do
      statements = capture_statements do
        migrate AddIndexConcurrently
      end
    end

    assert statements.any? { |s| s.start_with?("ANALYZE") }, "expected ANALYZE to run"
    refute(statements.any? { |s| s.include?("pg_locks") }, "expected no pg_locks query when non_blocking_lock_timeout is unset")
  ensure
    migrate AddIndexConcurrently, direction: :down if postgresql?
  end

  # SHARE allows the index build but blocks ANALYZE
  # while ANALYZE waits, add_column still holds ACCESS EXCLUSIVE on devices
  def test_non_blocking_lock_timeout_analyze_does_not_apply_after_access_exclusive_lock
    skip unless postgresql?

    # the transaction rolls back both the column and index on a lock timeout
    with_option(:non_blocking_lock_timeout, 0) do
      with_auto_analyze do
        with_lock_timeout_retries(lock: false) do
          with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
            with_locked_table("users", mode: "SHARE") do
              assert_raises(ActiveRecord::LockWaitTimeout) do
                migrate AddColumnAndNonConcurrentIndexWithAutoAnalyze
              end
            end
          end
        end
      end
    end
  end

  # SHARE on devices blocks writes until the transaction ends
  def test_non_blocking_lock_timeout_does_not_apply_after_share_lock
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    # validate a check constraint (not a foreign key) so application_blocking_lock_held?,
    # not the unconditional foreign-key exclusion, is what denies the override
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_share_lock", validate: false

    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          # EXCLUSIVE conflicts with the SHARE UPDATE EXCLUSIVE lock needed to validate the check constraint
          with_locked_table("users", mode: "EXCLUSIVE") do
            assert_raises(ActiveRecord::LockWaitTimeout) do
              migrate LockDevicesShareModeThenValidateConstraint
            end
          end
        end
      end
    end
  ensure
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :users, name: "credit_check_share_lock", if_exists: true if postgresql?
  end

  # EXCLUSIVE on devices blocks writes until the transaction ends
  def test_non_blocking_lock_timeout_does_not_apply_after_exclusive_lock
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    # validate a check constraint (not a foreign key) so application_blocking_lock_held?,
    # not the unconditional foreign-key exclusion, is what denies the override
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_exclusive_lock", validate: false

    with_option(:non_blocking_lock_timeout, 0) do
      with_lock_timeout_retries(lock: false) do
        with_statement_timeout(NORMAL_LOCK_TIMEOUT * 20) do
          # EXCLUSIVE conflicts with the SHARE UPDATE EXCLUSIVE lock needed to validate the check constraint
          with_locked_table("users", mode: "EXCLUSIVE") do
            assert_raises(ActiveRecord::LockWaitTimeout) do
              migrate LockDevicesExclusiveModeThenValidateConstraint
            end
          end
        end
      end
    end
  ensure
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint :users, name: "credit_check_exclusive_lock", if_exists: true if postgresql?
  end

  # UPDATE holds row locks until the transaction ends
  # validation must keep the normal timeout while those locks block other writers
  def test_non_blocking_lock_timeout_does_not_apply_after_row_lock
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.execute("INSERT INTO users (credit_score) VALUES (1)")
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_row_lock", validate: false

    lock_timeout = 0.05
    with_option(:lock_timeout, lock_timeout) do
      with_option(:lock_timeout_retries, 0) do
        with_option(:non_blocking_lock_timeout, 0) do
          with_statement_timeout(lock_timeout * 20) do
            with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
              assert_raises(ActiveRecord::LockWaitTimeout) do
                migrate UpdateCreditScoreThenValidateCheckConstraint
              end
            end
          end
        end
      end
    end
  ensure
    if postgresql?
      connection = ActiveRecord::Base.connection
      connection.remove_check_constraint :users, name: "credit_check_row_lock", if_exists: true
      connection.execute("DELETE FROM users WHERE credit_score IN (1, 2)")
    end
  end

  # locking reads preserve earlier query cache entries, while UPDATE clears them
  # keep this test separate from the UPDATE case to cover stale lock queries
  def test_non_blocking_lock_timeout_does_not_apply_after_cached_guard_row_lock
    skip unless postgresql?

    connection = ActiveRecord::Base.connection
    connection.execute("INSERT INTO users (credit_score) VALUES (1)")
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_cached_guard_row_lock", validate: false

    lock_timeout = 0.05
    with_option(:lock_timeout, lock_timeout) do
      with_option(:lock_timeout_retries, 0) do
        with_option(:non_blocking_lock_timeout, 0) do
          with_statement_timeout(lock_timeout * 20) do
            with_locked_table("users", mode: "SHARE UPDATE EXCLUSIVE") do
              assert_raises(ActiveRecord::LockWaitTimeout) do
                migrate ValidateCheckConstraintAfterCachedGuardRowLock
              end
            end
          end
        end
      end
    end
  ensure
    if postgresql?
      connection = ActiveRecord::Base.connection
      connection.remove_check_constraint :users, name: "credit_check_cached_guard_row_lock", if_exists: true
      connection.execute("DELETE FROM users WHERE credit_score = 1")
    end
  end

  # foreign key validation leaves ROW SHARE on the referenced table
  # that lock also prevents the later check validation from using the override
  def test_non_blocking_lock_timeout_does_not_apply_after_foreign_key_validation_in_same_transaction
    skip unless postgresql?

    add_not_valid_foreign_key
    connection = ActiveRecord::Base.connection
    connection.add_check_constraint :users, "credit_score > 0", name: "credit_check_after_fk", validate: false

    result, observations =
      with_option(:lock_timeout, NORMAL_LOCK_TIMEOUT) do
        with_option(:non_blocking_lock_timeout, 0) do
          observe_validate_constraint_lock_timeout_during { migrate(ValidateForeignKeyThenValidateCheckConstraint) }
        end
      end
    assert result

    assert_equal ["100ms", "100ms"], observations
  ensure
    if postgresql?
      remove_not_valid_foreign_key
      ActiveRecord::Base.connection.remove_check_constraint :users, name: "credit_check_after_fk", if_exists: true
    end
  end

  def reset_timeouts
    StrongMigrations.lock_timeout = nil
    StrongMigrations.transaction_timeout = nil
    StrongMigrations.statement_timeout = nil
    if postgresql?
      ActiveRecord::Base.connection.execute("RESET lock_timeout")
      ActiveRecord::Base.connection.execute("RESET transaction_timeout") if transaction_timeout?
      ActiveRecord::Base.connection.execute("RESET statement_timeout")
    elsif mysql?
      ActiveRecord::Base.connection.execute("SET max_execution_time = DEFAULT")
      ActiveRecord::Base.connection.execute("SET lock_wait_timeout = DEFAULT")
    elsif mariadb?
      ActiveRecord::Base.connection.execute("SET max_statement_time = DEFAULT")
      ActiveRecord::Base.connection.execute("SET lock_wait_timeout = DEFAULT")
    end
  end

  def with_lock_timeout_retries(lock: true)
    StrongMigrations.lock_timeout = postgresql? ? NORMAL_LOCK_TIMEOUT : 1
    StrongMigrations.lock_timeout_retries = 2
    StrongMigrations.lock_timeout_retry_delay = 0
    $migrate_attempts = 0
    $transaction_attempts = 0

    if lock
      with_locked_table("users") do
        yield
      end
    else
      yield
    end
  ensure
    StrongMigrations.lock_timeout_retries = 0
    StrongMigrations.lock_timeout_retry_delay = 5
  end

  def assert_retries(migration, retries: 2, **options)
    retry_count = 0
    original_say = nil
    count = proc do |message, *args, **options|
      original_say.call(message, *args, **options)
      retry_count += 1 if message.include?("Lock timeout")
    end

    assert_raises(ActiveRecord::LockWaitTimeout) do
      with_lock_timeout_retries(**options) do
        migration = migration.new
        original_say = migration.method(:say)
        migration.define_singleton_method(:say, count)
        migrate migration
      end
    end
    assert_equal retries, retry_count
  end

  def refute_retries(migration, **options)
    assert_retries(migration, retries: 0, **options)
  end

  def add_not_valid_foreign_key(name: nil)
    options = {validate: false}
    options[:name] = name if name
    ActiveRecord::Base.connection.add_foreign_key :users, :orders, **options
  end

  def remove_not_valid_foreign_key
    connection = ActiveRecord::Base.connection
    connection.remove_foreign_key :users, :orders if connection.foreign_key_exists?(:users, :orders)
  end

  # run a migration directly, bypassing the shared schema_migrations bookkeeping
  # that the migrate() helper does - table_name_prefix/suffix rename that table too,
  # so it stops existing for the duration of a with_table_name_prefix/suffix block
  def migrate_instance(migration_class, version: 123)
    migration = migration_class.new
    migration.version = version
    migration.migrate(:up)
    true
  rescue => e
    raise e.cause || e
  end

  # table_name_prefix and table_name_suffix are global, so save and restore them
  def with_table_name_prefix(prefix)
    previous_value = ActiveRecord::Base.table_name_prefix
    begin
      ActiveRecord::Base.table_name_prefix = prefix
      yield
    ensure
      ActiveRecord::Base.table_name_prefix = previous_value
    end
  end

  def with_table_name_suffix(suffix)
    previous_value = ActiveRecord::Base.table_name_suffix
    begin
      ActiveRecord::Base.table_name_suffix = suffix
      yield
    ensure
      ActiveRecord::Base.table_name_suffix = previous_value
    end
  end
end
