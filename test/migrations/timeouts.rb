class CheckTimeouts < TestMigration
  include Helpers

  def change
    safety_assured { execute "SELECT 1" }

    $statement_timeout =
      if postgresql?
        connection.select_all("SHOW statement_timeout").first["statement_timeout"]
      elsif mysql?
        connection.select_all("SHOW VARIABLES LIKE 'max_execution_time'").first["Value"].to_i / 1000.0
      else
        connection.select_all("SHOW VARIABLES LIKE 'max_statement_time'").first["Value"].to_f
      end

    $transaction_timeout =
      if postgresql? && transaction_timeout?
        connection.select_all("SHOW transaction_timeout").first["transaction_timeout"]
      end

    $lock_timeout =
      if postgresql?
        connection.select_all("SHOW lock_timeout").first["lock_timeout"]
      else
        connection.select_all("SHOW VARIABLES LIKE 'lock_wait_timeout'").first["Value"].to_i
      end
  end
end

class CheckTransactionTimeoutWithoutStatement < TestMigration
  include Helpers

  def change
    $transaction_timeout =
      if postgresql? && transaction_timeout?
        connection.select_all("SHOW transaction_timeout").first["transaction_timeout"]
      end
  end
end

class CheckLockTimeout < TestMigration
  def change
    safety_assured { execute "SELECT 1" }
  end
end

class CheckLockTimeoutRetries < TestMigration
  def change
    $migrate_attempts += 1
    add_column :users, :nice, :boolean
  end
end

class CheckLockTimeoutRetriesTransaction < TestMigration
  disable_ddl_transaction!

  def change
    $migrate_attempts += 1

    transaction do
      $transaction_attempts += 1
      add_column :users, :nice, :boolean
    end
  end
end

class CheckLockTimeoutRetriesTransactionDdlTransaction < TestMigration
  def change
    $migrate_attempts += 1

    transaction do
      $transaction_attempts += 1
      add_column :users, :nice, :boolean
    end
  end
end

class CheckLockTimeoutRetriesNoDdlTransaction < TestMigration
  disable_ddl_transaction!

  def change
    $migrate_attempts += 1
    add_column :users, :nice, :boolean
  end
end

class CheckLockTimeoutRetriesCommitDbTransaction < TestMigration
  def change
    $migrate_attempts += 1
    commit_db_transaction

    # no longer in DDL transaction

    begin_db_transaction
    add_column :users, :nice, :boolean
  end
end

class CheckLockTimeoutAfterConcurrentIndex < TestMigration
  disable_ddl_transaction!

  def up
    add_index :users, :name, algorithm: :concurrently
    $lock_timeout_after = connection.select_all("SHOW lock_timeout").first["lock_timeout"]
  end

  def down
    remove_index :users, :name, algorithm: :concurrently
  end
end

class ValidateForeignKeyOnly < TestMigration
  disable_ddl_transaction!

  def up
    validate_foreign_key :users, :orders
  end
end

class LockDevicesAccessExclusiveModeThenValidateConstraint < TestMigration
  def up
    connection.execute("LOCK devices IN ACCESS EXCLUSIVE MODE")
    validate_constraint :users, "credit_check_access_exclusive_lock"
  end
end

class ValidateConstraintOnly < TestMigration
  def up
    validate_constraint :users, "review_fk"
  end
end

class ValidateConstraintCheckConstraintOnly < TestMigration
  def up
    validate_constraint :users, "credit_check_by_name"
  end
end

class ValidateConstraintNotNullOnly < TestMigration
  def up
    validate_constraint :users, "city_not_null_check"
  end
end

class ValidateCheckConstraintInTransaction < TestMigration
  def up
    validate_check_constraint :users, name: "credit_check"
  end
end

class ValidateCheckConstraintOnly < TestMigration
  def up
    validate_check_constraint :users, name: "credit_check_only"
  end
end

class ValidateCheckConstraintWithLocalLockTimeout < TestMigration
  def up
    connection.execute("SET LOCAL lock_timeout = '1s'")
    validate_check_constraint :users, name: "credit_check_local_timeout"
  end
end

class AddUniqueIndexConcurrentlyDupCheck < TestMigration
  disable_ddl_transaction!

  def change
    add_index :users, :name, unique: true, algorithm: :concurrently, name: "index_users_on_name_dup_check"
  end
end

class AddIndexSafeByDefault < TestMigration
  def change
    add_index :users, :name
  end
end

class RevertAddIndexConcurrently < TestMigration
  disable_ddl_transaction!

  def up
    revert do
      add_index :users, :name, algorithm: :concurrently
    end
  end
end

class AddIndexConcurrentlyMissingColumn < TestMigration
  disable_ddl_transaction!

  def change
    add_index :users, :missing_column, algorithm: :concurrently
  end
end

class AddColumnAndNonConcurrentIndexWithAutoAnalyze < TestMigration
  def up
    add_column :devices, :extra, :string
    safety_assured { add_index :users, :name }
  end

  def down
    safety_assured { remove_index :users, :name }
    remove_column :devices, :extra
  end
end

# an ordinary transactional index build - CREATE INDEX takes SHARE, which
# does not conflict with another session's SHARE lock, but the ANALYZE that
# follows needs SHARE UPDATE EXCLUSIVE, which does
class AddIndexNonConcurrentlyWithAutoAnalyze < TestMigration
  def change
    safety_assured { add_index :users, :name }
  end
end

class LockDevicesShareModeThenValidateConstraint < TestMigration
  def up
    connection.execute("LOCK devices IN SHARE MODE")
    validate_constraint :users, "credit_check_share_lock"
  end
end

class LockDevicesExclusiveModeThenValidateConstraint < TestMigration
  def up
    connection.execute("LOCK devices IN EXCLUSIVE MODE")
    validate_constraint :users, "credit_check_exclusive_lock"
  end
end

class UpdateCreditScoreThenValidateCheckConstraint < TestMigration
  def up
    safety_assured { execute "UPDATE users SET credit_score = 2 WHERE credit_score = 1" }
    validate_check_constraint :users, name: "credit_check_row_lock"
  end
end

# remove_index checks held locks without issuing a DROP
# User.lock takes a row lock without clearing earlier query cache entries
class ValidateCheckConstraintAfterCachedGuardRowLock < TestMigration
  def up
    connection.cache do
      remove_index :users, name: "cached_guard_nonexistent_index", algorithm: :concurrently, if_exists: true
      User.lock.first
      validate_check_constraint :users, name: "credit_check_cached_guard_row_lock"
    end
  end
end

class ValidateForeignKeyThenValidateCheckConstraint < TestMigration
  def up
    validate_foreign_key :users, :orders
    validate_check_constraint :users, name: "credit_check_after_fk"
  end
end

# the checker sees this unresolved logical name (:items); Rails applies
# table_name_prefix/table_name_suffix, or a model class's table_name,
# afterwards in ActiveRecord::Migration#method_missing
class ValidateConstraintByTableName < TestMigration
  def up
    validate_constraint :items, "predicate_check"
  end
end

# a model class whose table_name differs from its inferred name
class ItemWithCustomTableName < ActiveRecord::Base
  self.table_name = "custom_named_items"
end

class ValidateConstraintByModelClass < TestMigration
  def up
    validate_constraint ItemWithCustomTableName, "predicate_check"
  end
end

class AddIndexConcurrentlyByTableName < TestMigration
  disable_ddl_transaction!

  def up
    add_index :items, :amount, algorithm: :concurrently
  end
end
