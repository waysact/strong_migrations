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




# remove_index checks held locks without issuing a DROP
# User.lock takes a row lock without clearing earlier query cache entries

