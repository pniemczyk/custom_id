# frozen_string_literal: true

module CustomId
  # Optional database-side ID generation using PostgreSQL, MySQL or SQLite triggers.
  #
  # This is an *alternative* to the Ruby-side {CustomId::Concern} approach.
  # Both achieve the same goal – prefixed, collision-resistant string IDs –
  # but this module offloads the work to the database engine.
  #
  # ## Trade-offs vs. the Ruby concern
  #
  # | Aspect             | Ruby concern          | DbExtension (DB trigger)   |
  # |--------------------|----------------------|----------------------------|
  # | Portability        | Any AR adapter       | PG, MySQL, SQLite only     |
  # | Bulk inserts       | Per-record callbacks | Handled by the DB          |
  # | Raw SQL inserts    | IDs not generated    | IDs always generated        |
  # | Testability        | Easy (SQLite ok)     | Needs a real DB connection |
  # | Migration needed   | No                   | Yes (install/uninstall)     |
  #
  # ## Requirements
  #
  # * **PostgreSQL**: 9.6+ (uses +gen_random_bytes+ from the +pgcrypto+ extension).
  # * **MySQL**: 5.7+ (uses +RANDOM_BYTES+).
  # * **SQLite**: 3.0+ (uses +randomblob+). Non-PK columns use an AFTER INSERT
  #   trigger; NOT NULL primary key columns use a BEFORE INSERT trigger with
  #   RAISE(IGNORE) so the row is inserted with a generated ID before SQLite
  #   evaluates the NOT NULL constraint on the outer statement.
  #
  # ## Usage in migrations (PostgreSQL example)
  #
  #   class CreateUsers < ActiveRecord::Migration[7.0]
  #     def up
  #       enable_extension "pgcrypto"   # once per database
  #
  #       create_table :users, id: :string do |t|
  #         t.string :name, null: false
  #         t.timestamps
  #       end
  #
  #       CustomId::DbExtension.install_trigger!(connection, :users, prefix: "usr")
  #     end
  #
  #     def down
  #       CustomId::DbExtension.uninstall_trigger!(connection, :users)
  #       drop_table :users
  #     end
  #   end
  #
  # @note The shared-characters feature available in {CustomId::Concern} is
  #   intentionally omitted here because cross-table lookups inside a trigger
  #   introduce concurrency risks and make schema evolution painful.
  module DbExtension
    # rubocop:disable Style/MutableConstant
    # Adapters considered PostgreSQL-compatible.
    PG_ADAPTERS = %w[postgresql postgis].freeze
    MYSQL_ADAPTERS = %w[mysql mysql2 trilogy].freeze
    SQLITE_ADAPTERS = %w[sqlite sqlite3].freeze

    SUPPORTED_ADAPTERS = (PG_ADAPTERS + MYSQL_ADAPTERS + SQLITE_ADAPTERS).freeze

    # Base58 characters
    ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    # --- PostgreSQL SQL ------------------------------------------------------

    # SQL that creates (or replaces) the reusable Base58 generator function.
    # Depends on +pgcrypto+'s +gen_random_bytes+.
    PG_GENERATE_FUNCTION_SQL = <<~SQL
      CREATE OR REPLACE FUNCTION custom_id_base58(p_size INT DEFAULT 16)
      RETURNS TEXT AS $$
      DECLARE
        chars      TEXT    := '#{ALPHABET}';
        result     TEXT    := '';
        i          INT;
        rand_bytes BYTEA;
      BEGIN
        rand_bytes := gen_random_bytes(p_size);
        FOR i IN 0..p_size - 1 LOOP
          result := result || substr(chars, (get_byte(rand_bytes, i) % 58) + 1, 1);
        END LOOP;
        RETURN result;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    # SQL that removes the shared Base58 generator function.
    PG_DROP_GENERATE_FUNCTION_SQL = "DROP FUNCTION IF EXISTS custom_id_base58(INT);"

    # --- MySQL SQL -----------------------------------------------------------

    # MySQL implementation of Base58 generator.
    # Note: RANDOM_BYTES(N) returns binary data.
    MYSQL_GENERATE_FUNCTION_SQL = <<~SQL
      CREATE FUNCTION IF NOT EXISTS custom_id_base58(p_size INT)
      RETURNS TEXT DETERMINISTIC
      BEGIN
        DECLARE chars TEXT DEFAULT '#{ALPHABET}';
        DECLARE result TEXT DEFAULT '';
        DECLARE i INT DEFAULT 0;
        WHILE i < p_size DO
          SET result = CONCAT(result, SUBSTR(chars, (ORD(RANDOM_BYTES(1)) % 58) + 1, 1));
          SET i = i + 1;
        END WHILE;
        RETURN result;
      END;
    SQL

    # rubocop:enable Style/MutableConstant

    MYSQL_DROP_GENERATE_FUNCTION_SQL = "DROP FUNCTION IF EXISTS custom_id_base58;"

    # Returns +true+ when +connection+ targets a supported adapter.
    #
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @return [Boolean]
    def self.supported?(connection)
      SUPPORTED_ADAPTERS.include?(connection.adapter_name.downcase)
    end

    # Installs the shared Base58 generator function into the database.
    # Safe to call multiple times (uses +CREATE OR REPLACE+ or +IF NOT EXISTS+).
    #
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @raise [NotImplementedError] when the adapter is not supported or (PG only)
    #   when the pgcrypto extension is not enabled.
    def self.install_generate_function!(connection)
      assert_supported!(connection)

      case connection.adapter_name.downcase
      when *PG_ADAPTERS
        pg_assert_pgcrypto!(connection)
        connection.execute(PG_GENERATE_FUNCTION_SQL)
      when *MYSQL_ADAPTERS
        connection.execute(MYSQL_GENERATE_FUNCTION_SQL)
      when *SQLITE_ADAPTERS
        # SQLite doesn't support stored functions in the same way.
        # We'll embed the logic directly in the trigger.
      end
    end

    # Removes the shared Base58 generator function from the database.
    #
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @raise [NotImplementedError] when the adapter is not supported.
    def self.uninstall_generate_function!(connection)
      assert_supported!(connection)

      case connection.adapter_name.downcase
      when *PG_ADAPTERS
        connection.execute(PG_DROP_GENERATE_FUNCTION_SQL)
      when *MYSQL_ADAPTERS
        connection.execute(MYSQL_DROP_GENERATE_FUNCTION_SQL)
      end
    end

    # Installs both the per-table trigger function and the BEFORE INSERT trigger
    # on +table_name+, auto-generating a prefixed custom ID when the column is NULL.
    #
    # Idempotent: uses +CREATE OR REPLACE FUNCTION+ and +DROP TRIGGER IF EXISTS+
    # before re-creating the trigger.
    #
    # @param connection  [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @param table_name  [String, Symbol]  Target table.
    # @param prefix      [String]          ID prefix (e.g. "usr").
    # @param column      [Symbol, String]  Column to populate (default: :id).
    # @param size        [Integer]         Length of the random portion (default: 16).
    # @raise [NotImplementedError] when the adapter is not supported.
    #
    # @note **MySQL + ActiveRecord string PKs:** MySQL's protocol does not return a
    #   trigger-generated string PK to the caller (unlike PostgreSQL's +RETURNING+).
    #   After an AR +create+, Rails reads +LAST_INSERT_ID()+ which returns +0+ for
    #   non-AUTO_INCREMENT columns, leaving the in-memory record with +id = "0"+
    #   while the database row is correct.  Fix: also declare +cid+ on the model
    #   so that AR generates the ID in Ruby before the INSERT.  The trigger then
    #   acts only as a safety net for raw-SQL inserts that bypass ActiveRecord.
    def self.install_trigger!(connection, table_name, prefix:, column: :id, size: 16)
      assert_supported!(connection)

      adapter = connection.adapter_name.downcase
      case adapter
      when *PG_ADAPTERS
        pg_assert_pgcrypto!(connection)
        connection.execute(PG_GENERATE_FUNCTION_SQL)
        connection.execute(pg_trigger_function_sql(table_name, prefix: prefix, column: column, size: size))
        connection.execute(pg_create_trigger_sql(table_name, column: column))
      when *MYSQL_ADAPTERS
        connection.execute(MYSQL_GENERATE_FUNCTION_SQL)
        # mysql2/trilogy execute only one statement per call, so DROP and CREATE
        # must be sent separately (unlike PG which accepts multi-statement strings).
        connection.execute(mysql_drop_trigger_sql(table_name, column: column))
        connection.execute(mysql_create_trigger_sql(table_name, prefix: prefix, column: column, size: size))
      when *SQLITE_ADAPTERS
        sqlite_install_trigger!(connection, table_name, prefix: prefix, column: column, size: size)
      end
    end

    # Drops the per-table trigger and its companion trigger function from +table_name+.
    #
    # @param connection  [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @param table_name  [String, Symbol] Target table.
    # @param column      [Symbol, String] Column the trigger was installed on (default: :id).
    # @raise [NotImplementedError] when the adapter is not supported.
    def self.uninstall_trigger!(connection, table_name, column: :id)
      assert_supported!(connection)

      adapter = connection.adapter_name.downcase
      case adapter
      when *PG_ADAPTERS
        connection.execute(pg_drop_trigger_sql(table_name, column: column))
      when *MYSQL_ADAPTERS
        connection.execute(mysql_drop_trigger_sql(table_name, column: column))
      when *SQLITE_ADAPTERS
        connection.execute(sqlite_drop_trigger_sql(table_name, column: column))
      end
    end

    # --- Private helpers -----------------------------------------------------

    # Raises +NotImplementedError+ when the pgcrypto extension is absent.
    # Called before installing any PostgreSQL function or trigger so the error
    # surface is at install time rather than at the first INSERT.
    private_class_method def self.pg_assert_pgcrypto!(connection)
      enabled = connection.select_value(
        "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgcrypto'"
      ).to_i.positive?
      return if enabled

      raise NotImplementedError,
            "The pgcrypto PostgreSQL extension is required but not enabled. " \
            "Run: rails custom_id:db:enable_pgcrypto " \
            "or add enable_extension \"pgcrypto\" to a migration."
    end

    private_class_method def self.assert_supported!(connection)
      return if supported?(connection)

      raise NotImplementedError,
            "CustomId::DbExtension does not support #{connection.adapter_name}. " \
            "Supported: #{SUPPORTED_ADAPTERS.join(", ")}. " \
            "Use CustomId::Concern for other databases."
    end

    private_class_method def self.trigger_function_name(table_name, column)
      "#{table_name}_#{column}_custom_id"
    end

    private_class_method def self.trigger_name(table_name, column)
      "#{table_name}_#{column}_before_insert_custom_id"
    end

    # --- PostgreSQL specific helpers ---

    private_class_method def self.pg_trigger_function_sql(table_name, prefix:, column:, size:)
      func = trigger_function_name(table_name, column)
      "CREATE OR REPLACE FUNCTION #{func}()\nRETURNS TRIGGER AS $$\nBEGIN\n  IF NEW.#{column} IS NULL THEN\n    NEW.#{column} := '#{prefix}_' || custom_id_base58(#{size});\n  END IF;\n  RETURN NEW;\nEND;\n$$ LANGUAGE plpgsql;\n" # rubocop:disable Layout/LineLength
    end

    private_class_method def self.pg_create_trigger_sql(table_name, column:)
      trig = trigger_name(table_name, column)
      fn   = trigger_function_name(table_name, column)
      <<~SQL
        DROP TRIGGER IF EXISTS #{trig} ON #{table_name};
        CREATE TRIGGER #{trig}
          BEFORE INSERT ON #{table_name}
          FOR EACH ROW EXECUTE FUNCTION #{fn}();
      SQL
    end

    private_class_method def self.pg_drop_trigger_sql(table_name, column:)
      trig = trigger_name(table_name, column)
      fn   = trigger_function_name(table_name, column)
      <<~SQL
        DROP TRIGGER IF EXISTS #{trig} ON #{table_name};
        DROP FUNCTION IF EXISTS #{fn}();
      SQL
    end

    # --- MySQL specific helpers ---

    # Returns only the CREATE TRIGGER statement – the caller is responsible for
    # dropping any existing trigger first (mysql2/trilogy reject multi-statement strings).
    private_class_method def self.mysql_create_trigger_sql(table_name, prefix:, column:, size:)
      trig = trigger_name(table_name, column)
      <<~SQL
        CREATE TRIGGER #{trig}
          BEFORE INSERT ON #{table_name}
          FOR EACH ROW
          BEGIN
            IF NEW.#{column} IS NULL THEN
              SET NEW.#{column} = CONCAT('#{prefix}_', custom_id_base58(#{size}));
            END IF;
          END;
      SQL
    end

    private_class_method def self.mysql_drop_trigger_sql(table_name, column:)
      trig = trigger_name(table_name, column)
      "DROP TRIGGER IF EXISTS #{trig};"
    end

    # --- SQLite specific helpers ---

    private_class_method def self.sqlite_create_trigger_sql(table_name, prefix:, column:, size:)
      trig = trigger_name(table_name, column)
      # We generate the Base58 string by concatenating random characters from the ALPHABET.
      generator = Array.new(size) { "substr('#{ALPHABET}', (abs(random()) % 58) + 1, 1)" }.join(" || ")

      # In SQLite, we use an AFTER INSERT trigger to update the row.
      # We use rowid to identify the row, as it is always present even if not explicitly defined.
      <<~SQL
        CREATE TRIGGER IF NOT EXISTS #{trig} AFTER INSERT ON #{table_name}
        FOR EACH ROW
        WHEN NEW.#{column} IS NULL
        BEGIN
          UPDATE #{table_name} SET #{column} = '#{prefix}_' || (#{generator}) WHERE rowid = NEW.rowid;
        END;
      SQL
    end

    private_class_method def self.sqlite_drop_trigger_sql(table_name, column:)
      trig = trigger_name(table_name, column)
      "DROP TRIGGER IF EXISTS #{trig};"
    end

    # Dispatches to the correct SQLite trigger strategy:
    # * Non-PK / nullable column → AFTER INSERT trigger (updates the row in-place).
    # * NOT NULL primary key → BEFORE INSERT trigger with RAISE(IGNORE) so the
    #   row is inserted with a generated id before SQLite checks the NOT NULL
    #   constraint on the original (id-less) outer statement.
    #
    # NOTE: When the BEFORE INSERT path is used, SQLite's RETURNING clause on
    # the outer INSERT sees the original NULL value (the outer INSERT was
    # abandoned via RAISE(IGNORE)).  After +create+, call +reload+ on the record
    # to obtain the correct id from the database.
    private_class_method def self.sqlite_install_trigger!(connection, table_name, prefix:, column:, size:)
      if sqlite_pk_not_null?(connection, table_name, column)
        sql = sqlite_create_pk_trigger_sql(connection, table_name, prefix: prefix, column: column, size: size)
        connection.execute(sql)
      else
        connection.execute(sqlite_create_trigger_sql(table_name, prefix: prefix, column: column, size: size))
      end
    end

    # Builds the BEFORE INSERT + RAISE(IGNORE) trigger used when the target
    # column is a NOT NULL primary key.  The trigger body:
    # 1. Inserts the row with a generated id (the WHEN guard prevents recursion).
    # 2. Calls RAISE(IGNORE) to silently abandon the outer NULL-id statement.
    private_class_method def self.sqlite_create_pk_trigger_sql(connection, table_name, prefix:, column:, size:)
      trig = trigger_name(table_name, column)
      generator = Array.new(size) { "substr('#{ALPHABET}', (abs(random()) % 58) + 1, 1)" }.join(" || ")
      col_list, val_list = sqlite_pk_col_and_val_lists(connection, table_name, column, prefix, generator)
      <<~SQL
        CREATE TRIGGER IF NOT EXISTS #{trig} BEFORE INSERT ON #{table_name}
        FOR EACH ROW WHEN NEW.#{column} IS NULL
        BEGIN
          INSERT INTO #{table_name} (#{col_list}) VALUES (#{val_list});
          SELECT RAISE(IGNORE);
        END;
      SQL
    end

    # Returns [col_list, val_list] strings for the inner INSERT inside the
    # BEFORE INSERT trigger.  The target +column+ gets the generated id
    # expression; every other column gets the corresponding NEW.column value.
    private_class_method def self.sqlite_pk_col_and_val_lists(connection, table_name, column, prefix, generator)
      cols = connection.columns(table_name.to_s).map(&:name)
      val_list = cols.map do |c|
        c == column.to_s ? "'#{prefix}_' || (#{generator})" : "NEW.#{c}"
      end.join(", ")
      [cols.join(", "), val_list]
    end

    # Returns true when +column+ is the NOT NULL primary key of +table_name+.
    # This is the case where an AFTER INSERT trigger cannot fire (the NOT NULL
    # constraint blocks the INSERT first) and the BEFORE INSERT path is needed.
    private_class_method def self.sqlite_pk_not_null?(connection, table_name, column)
      pk = connection.primary_key(table_name.to_s)
      return false unless pk == column.to_s

      col = connection.columns(table_name.to_s).find { |c| c.name == column.to_s }
      col && !col.null
    end
  end
end
