# frozen_string_literal: true

require "test_helper"
require "active_record"
require "sqlite3"

module CustomId
  class SQLiteDbExtensionTest < Minitest::Test
    def setup
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      @connection = ActiveRecord::Base.connection
      @connection.create_table :users do |t| # This creates an auto-increment integer 'id' and a rowid implicitly
        t.string :custom_id # We'll use this column for CustomId
        t.string :name
      end
    end

    def teardown
      @connection.drop_table :users if @connection.table_exists?(:users)
    end

    def test_db_extension_sqlite_integration
      CustomId::DbExtension.install_trigger!(@connection, :users, prefix: "usr", column: :custom_id, size: 8)

      @connection.execute("INSERT INTO users (name) VALUES ('Charlie')")
      user = @connection.select_one("SELECT * FROM users WHERE name = 'Charlie'")
      assert_match(%r{^usr_[1-9A-HJ-NP-Za-km-z]{8}$}, user["custom_id"]) # rubocop:disable Style/RegexpLiteral

      # Test with explicit ID (should not be overwritten)
      @connection.execute("INSERT INTO users (custom_id, name) VALUES ('explicit_1', 'Delta')")
      user = @connection.select_one("SELECT * FROM users WHERE name = 'Delta'")
      assert_equal "explicit_1", user["custom_id"]
    end

    def test_uninstall_trigger
      CustomId::DbExtension.install_trigger!(@connection, :users, prefix: "usr", column: :custom_id)
      CustomId::DbExtension.uninstall_trigger!(@connection, :users, column: :custom_id)

      @connection.execute("INSERT INTO users (name) VALUES ('Echo')")
      user = @connection.select_one("SELECT * FROM users WHERE name = 'Echo'")
      assert_nil user["custom_id"]
    end
  end

  # Covers the NOT NULL primary key case for SQLite.
  # An AFTER INSERT trigger cannot fire when NOT NULL blocks the INSERT first, so
  # the implementation uses BEFORE INSERT + RAISE(IGNORE) instead.
  class SQLiteDbExtensionPkTest < Minitest::Test
    def setup
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      @connection = ActiveRecord::Base.connection
      @connection.create_table :items, id: :string, force: true do |t|
        t.string :name
      end
    end

    def teardown
      @connection.drop_table :items if @connection.table_exists?(:items)
    end

    def test_install_trigger_on_not_null_pk_inserts_row_with_generated_id
      CustomId::DbExtension.install_trigger!(@connection, :items, prefix: "itm", column: :id)

      @connection.execute("INSERT INTO items (name) VALUES ('Test')")
      item = @connection.select_one("SELECT * FROM items WHERE name = 'Test'")

      refute_nil item["id"]
      assert_match(/\Aitm_[1-9A-HJ-NP-Za-km-z]{16}\z/, item["id"])
    end

    def test_install_trigger_on_not_null_pk_does_not_overwrite_explicit_id
      CustomId::DbExtension.install_trigger!(@connection, :items, prefix: "itm", column: :id)

      @connection.execute("INSERT INTO items (id, name) VALUES ('itm_explicit', 'Test')")
      item = @connection.select_one("SELECT * FROM items WHERE name = 'Test'")

      assert_equal "itm_explicit", item["id"]
    end

    def test_install_trigger_on_not_null_pk_generates_unique_ids
      CustomId::DbExtension.install_trigger!(@connection, :items, prefix: "itm", column: :id)

      20.times { |i| @connection.execute("INSERT INTO items (name) VALUES ('Item #{i}')") }
      ids = @connection.select_all("SELECT id FROM items").rows.flatten

      assert_equal ids.length, ids.uniq.length, "Expected all generated IDs to be unique"
      assert ids.all? { |id| id&.match?(/\Aitm_/) }, "Expected all IDs to start with 'itm_'"
    end

    def test_install_trigger_on_not_null_pk_custom_size
      CustomId::DbExtension.install_trigger!(@connection, :items, prefix: "itm", column: :id, size: 8)

      @connection.execute("INSERT INTO items (name) VALUES ('Short')")
      item = @connection.select_one("SELECT * FROM items WHERE name = 'Short'")

      assert_match(/\Aitm_[1-9A-HJ-NP-Za-km-z]{8}\z/, item["id"])
    end

    def test_uninstall_trigger_on_not_null_pk_removes_behaviour
      CustomId::DbExtension.install_trigger!(@connection, :items, prefix: "itm", column: :id)
      CustomId::DbExtension.uninstall_trigger!(@connection, :items, column: :id)

      # Without the trigger the NOT NULL constraint must block a NULL-id INSERT.
      assert_raises(ActiveRecord::StatementInvalid) do
        @connection.execute("INSERT INTO items (name) VALUES ('After uninstall')")
      end
    end
  end
end
