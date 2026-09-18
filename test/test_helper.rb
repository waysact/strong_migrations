require "bundler/setup"
Bundler.require(:default)
require "minitest/autorun"

require_relative "support/active_record"
require_relative "support/helpers"

class Minitest::Test
  include Helpers

  def migrate(migration, direction: :up, version: 123)
    schema_migration.delete_all_versions
    migration = migration.new unless migration.is_a?(TestMigration)
    migration.version ||= version
    if direction == :down
      schema_migration.create_version(migration.version)
    end
    args = [schema_migration, connection_class.internal_metadata]
    ActiveRecord::Migrator.new(direction, [migration], *args).migrate
    true
  rescue => e
    raise e.cause || e
  end

  def assert_unsafe(migration, message = nil, **options)
    error = assert_raises(StrongMigrations::UnsafeMigration) do
      migrate(migration, **options)
    end
    puts error.message if ENV["VERBOSE"]
    assert_match message, error.message if message
  end

  def assert_safe(migration, direction: nil, **options)
    if direction
      assert migrate(migration, direction: direction, **options)
    else
      assert migrate(migration, direction: :up, **options)
      assert migrate(migration, direction: :down, **options)
    end
  end

  def assert_argument_error(migration)
    assert_raises(ArgumentError) do
      migrate(migration)
    end
  end

  def with_option(name, value)
    previous_value = StrongMigrations.send(name)
    begin
      StrongMigrations.send("#{name}=", value)
      yield
    ensure
      StrongMigrations.send("#{name}=", previous_value)
    end
  end

  def with_start_after(start_after, &block)
    with_option(:start_after, start_after, &block)
  end

  def with_target_version(version, &block)
    with_option(:target_version, version, &block)
  end

  def with_auto_analyze(&block)
    with_option(:auto_analyze, true, &block)
  end

  def with_analyze_failures(count)
    $analyze_attempts = 0
    $analyze_failures = count
    yield
  ensure
    $analyze_failures = 0
  end

  def with_safety_assured(&block)
    previous_value = StrongMigrations::Checker.safe
    begin
      StrongMigrations::Checker.safe = true
      yield
    ensure
      StrongMigrations::Checker.safe = previous_value
    end
  end

  def outside_developer_env(&block)
    previous_value = Rails.env
    begin
      Rails.env = ActiveSupport::StringInquirer.new("production")
      yield
    ensure
      Rails.env = previous_value
    end
  end

  def with_lock_timeout(lock_timeout, &block)
    with_option(:lock_timeout, lock_timeout, &block)
  ensure
    ActiveRecord::Base.connection.execute("RESET lock_timeout")
  end

  # hold a lock on another connection until the block exits
  # use for timeout assertions so releasing the lock cannot race the assertion
  def with_locked_table(table, mode: "ROW EXCLUSIVE")
    pool = ActiveRecord::Base.connection_pool
    connection = pool.checkout

    if postgresql?
      connection.transaction do
        connection.execute("LOCK TABLE #{connection.quote_table_name(table)} IN #{mode} MODE")
        yield
      end
    else
      begin
        connection.execute("LOCK TABLE #{connection.quote_table_name(table)} WRITE")
        yield
      ensure
        connection.execute("UNLOCK TABLES")
      end
    end
  ensure
    pool.checkin(connection) if connection
  end

  # bound the wait if a lock timeout fails to fire
  # use a multiple of lock_timeout so a regression raises QueryCanceled
  # instead of hanging, while a passing test raises LockWaitTimeout
  def with_statement_timeout(seconds)
    connection = ActiveRecord::Base.connection
    connection.execute("SET statement_timeout = #{(seconds * 1000).ceil}")
    yield
  ensure
    connection.execute("RESET statement_timeout")
  end

  # release the lock after the migration waits for outlast seconds
  # set outlast above lock_timeout to verify the timeout override
  # fail if no wait starts within ceiling seconds
  def with_lock_released_on_contention(table, outlast:, mode: "ROW EXCLUSIVE", ceiling: 15)
    waiter_pid = ActiveRecord::Base.connection.select_all("SELECT pg_backend_pid() AS pid").first["pid"].to_i
    pool = ActiveRecord::Base.connection_pool
    held = Queue.new
    thread = Thread.new do
      locked = false
      connection = nil
      begin
        connection = pool.checkout
        connection.transaction do
          connection.execute("LOCK TABLE #{connection.quote_table_name(table)} IN #{mode} MODE")
          held.push(true)
          locked = true
          wait_for_lock_contention(connection, waiter_pid, ceiling: ceiling)
          sleep(outlast)
        end
      ensure
        pool.checkin(connection) if connection
        # unblock the main thread if acquiring the lock fails
        # Thread#join propagates the error
        held.push(false) unless locked
      end
    end

    unless held.pop
      thread.join
      raise "lock holder exited without taking the lock on #{table}"
    end

    yield
  ensure
    # preserve the migration error if the lock holder also fails
    in_flight = $!
    begin
      thread&.join
    rescue StandardError
      raise unless in_flight
    end
  end

  def wait_for_lock_contention(connection, waiter_pid, ceiling:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ceiling
    # observe pg_stat_activity to detect both table and virtual transaction waits
    query = <<~SQL
      SELECT 1
      FROM pg_stat_activity
      WHERE pid = #{waiter_pid}
        AND wait_event_type = 'Lock'
    SQL
    loop do
      return if connection.select_all(query).any?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise "migration backend (pid #{waiter_pid}) was never observed waiting on a lock within #{ceiling}s"
      end
      sleep(0.05)
    end
  end

  # hold a lock on another connection until the migration announces a lock
  # timeout retry - the "Lock timeout" message that Checker#retry_lock_timeouts
  # says right before it retries - then release it
  #
  # pass defer_until_analyze: true to take the lock only immediately before a
  # real ANALYZE reaches the server, instead of up front - use this when the
  # lock mode would also block an earlier statement (such as
  # CREATE INDEX CONCURRENTLY) that needs the same lock level, so the lock
  # must not exist yet while that earlier statement runs
  #
  # returns the number of retries the migration announced
  def with_lock_released_on_retry(migration, table, mode: "ROW EXCLUSIVE", defer_until_analyze: false)
    pool = ActiveRecord::Base.connection_pool
    start = Queue.new
    acquired = Queue.new
    release = Queue.new
    released = Queue.new
    failure = nil
    lock_held = false

    $analyze_lock_rendezvous = {start: start, acquired: acquired} if defer_until_analyze

    thread = Thread.new do
      connection = nil
      begin
        go = defer_until_analyze ? start.pop : true
        if go
          connection = pool.checkout
          connection.transaction do
            connection.execute("LOCK TABLE #{connection.quote_table_name(table)} IN #{mode} MODE")
            lock_held = true
            acquired.push(true)
            release.pop
          end
        end
      rescue => e
        failure = e
        # unblock whoever is waiting on acquisition so the failure surfaces
        # instead of hanging the run
        acquired.push(true)
      ensure
        pool.checkin(connection) if connection
        # Signal only after the transaction has ended and released its lock,
        # so the retry cannot race the COMMIT.
        released.push(true)
      end
    end

    unless defer_until_analyze
      acquired.pop
      raise failure if failure
    end

    retry_count = 0
    waited = false
    # neither with_locked_table (releases only when its own block returns) nor
    # with_lock_released_on_contention (releases once it observes the migration
    # waiting) fits here: retry_lock_timeouts swallows the LockWaitTimeout that
    # would otherwise prove a real timeout occurred, so the lock has to be held
    # until that retry is announced and released right after, before the retried
    # attempt runs
    original_say = migration.method(:say)
    migration.define_singleton_method(:say, proc { |message, *say_args, **say_opts|
      original_say.call(message, *say_args, **say_opts)
      if message.include?("Lock timeout")
        retry_count += 1
        release.push(true)
        # Wait for the holder to release the lock. Waking it is not enough:
        # these tests retry immediately because lock_timeout_retry_delay is 0.
        #
        # Wait only if the lock has been acquired. With defer_until_analyze,
        # an earlier statement can time out before the holder starts. Waiting
        # then would time out and incorrectly report that the holder failed
        # to release its lock.
        if lock_held && !waited
          waited = true
          unless released.pop(timeout: 30)
            raise "lock holder did not end its transaction within 30 seconds"
          end
        end
      end
    })

    begin
      yield
    ensure
      release.push(true)
      # unblock the holder if it never got a start signal (say was never
      # called, e.g. the migration failed for an unrelated reason)
      start.push(false) if defer_until_analyze
      thread.join
      $analyze_lock_rendezvous = nil if defer_until_analyze
    end

    raise failure if failure

    retry_count
  end

  def index_valid?(name)
    connection = ActiveRecord::Base.connection
    # to_regclass returns NULL for a missing index, allowing the assertion to
    # report a failure instead of raising a database error.
    row = connection.select_all(
      "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(#{connection.quote(name)})"
    ).first
    row && row["indisvalid"]
  end

  def assert_analyzed(migration)
    assert analyzed?(migration)
  end

  def refute_analyzed(migration)
    refute analyzed?(migration)
  end

  def analyzed?(migration)
    statements = capture_statements do
      migrate migration, direction: :up
    end
    migrate migration, direction: :down
    statements.any? { |s| s.start_with?("ANALYZE") }
  end

  # return [block_result, observations] with one server timeout reading
  # per with_lock_timeout call, in call order
  def observe_lock_timeout_during
    $lock_timeout_observations = []
    result = yield
    [result, $lock_timeout_observations]
  ensure
    $lock_timeout_observations = nil
  end

  # return [block_result, observations] with one server timeout reading
  # per validate_constraint call, including foreign key and check validation
  def observe_validate_constraint_lock_timeout_during
    $validate_constraint_lock_timeouts = []
    result = yield
    [result, $validate_constraint_lock_timeouts]
  ensure
    $validate_constraint_lock_timeouts = nil
  end

  def capture_statements
    statements = []
    callback = lambda do |_, _, _, _, payload|
      statements << payload[:sql] if payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end
    statements
  end

  def ar_version
    ActiveRecord::VERSION::STRING.to_f
  end

  # not used for add_index (which supported it before)
  def algorithm_option?
    (mysql? || mariadb?) && ar_version >= 8.2
  end

  def lock_option?
    (mysql? || mariadb?) && ar_version >= 8.2
  end

  # Use the real connection to test adapter methods without running a migration.
  def adapter_for_current_connection
    connection = ActiveRecord::Base.connection
    checker = Object.new
    checker.define_singleton_method(:connection) { connection }
    StrongMigrations::Adapters::PostgreSQLAdapter.new(checker)
  end
end

StrongMigrations.add_check do |method, args|
  if method == :add_column && args[1].to_s == "forbidden"
    stop! "Cannot add forbidden column"
  end
end

# initialize here, at module definition time, so a test that triggers an
# ANALYZE without going through with_analyze_failures first does not trip
# a "not initialized" warning the first time these are read
$analyze_attempts = 0
$analyze_failures = 0

# inject ANALYZE failures after the index build succeeds
module AnalyzeFailures
  def analyze_table(table)
    $analyze_attempts = $analyze_attempts.to_i + 1
    if $analyze_failures.to_i > 0
      $analyze_failures -= 1
      raise ActiveRecord::LockWaitTimeout, "canceling statement due to lock timeout"
    end
    super
  end
end
StrongMigrations::Adapters::PostgreSQLAdapter.prepend(AnalyzeFailures)

$analyze_lock_rendezvous = nil

# let with_lock_released_on_retry(defer_until_analyze: true) delay taking its
# lock until immediately before a real ANALYZE reaches the server, then wait
# for confirmation that the lock is actually held before letting it through -
# consumed once, so retried ANALYZE calls pass straight through
module AnalyzeLockRendezvous
  def analyze_table(table)
    if (rendezvous = $analyze_lock_rendezvous)
      $analyze_lock_rendezvous = nil
      rendezvous[:start].push(true)
      rendezvous[:acquired].pop
    end
    super
  end
end
StrongMigrations::Adapters::PostgreSQLAdapter.prepend(AnalyzeLockRendezvous)

$lock_timeout_observations = nil

# read the server timeout inside each override, before running the statement
module LockTimeoutDuringObserver
  def with_lock_timeout(timeout, &block)
    return super unless $lock_timeout_observations
    super(timeout) do
      $lock_timeout_observations << connection.uncached { select_all("SHOW lock_timeout") }.first["lock_timeout"]
      block.call
    end
  end
end
StrongMigrations::Adapters::PostgreSQLAdapter.prepend(LockTimeoutDuringObserver)

$validate_constraint_lock_timeouts = nil

# both validate_foreign_key and validate_check_constraint call this method
# read the server timeout just before validation
module ValidateConstraintLockTimeoutObserver
  def validate_constraint(table_name, constraint_name)
    $validate_constraint_lock_timeouts << uncached { select_all("SHOW lock_timeout") }.first["lock_timeout"] if $validate_constraint_lock_timeouts
    super
  end
end
if defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(ValidateConstraintLockTimeoutObserver)
end

Dir.glob("migrations/*.rb", base: __dir__).sort.each do |file|
  require_relative file
end

# Provide a minimal Checker substitute for testing adapter predicates.
# Pass nil as the status to simulate a driver without transaction status support.
class FakeChecker
  FakeRawConnection = Struct.new(:transaction_status)

  def initialize(status, open_transactions: 0)
    @status = status
    @open_transactions = open_transactions
  end

  def connection
    raw = @status.nil? ? Object.new : FakeRawConnection.new(@status)
    FakeConnection.new(raw, @open_transactions)
  end

  FakeConnection = Struct.new(:raw_connection, :open_transactions)
end
