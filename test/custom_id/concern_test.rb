# frozen_string_literal: true

require "test_helper"

# ---------------------------------------------------------------------------
# Named model classes used across concern tests.
# Defined in a module namespace to avoid constant pollution and to allow
# belongs_to associations to resolve class names correctly.
# ---------------------------------------------------------------------------
module CidTestModels
  # Simple model with a string primary key – exercises the default cid setup.
  class Account < ActiveRecord::Base
    self.table_name = "cid_accounts"
    cid "acc"
  end

  # Model whose ID embeds the first N characters of a related model's ID.
  class Entry < ActiveRecord::Base
    self.table_name = "cid_entries"
    belongs_to :account, class_name: "CidTestModels::Account", optional: true
    cid "ent", size: 24, related: { account: 8 }
  end

  # Model that stores its custom ID in a non-primary-key column.
  # Uses a default integer primary key so SQLite handles the PK automatically.
  class Article < ActiveRecord::Base
    self.table_name = "cid_articles"
    cid "art", name: :slug, size: 10
  end
end

module CustomId
  class ConcernTest < Minitest::Test
    def setup
      create_accounts_table
      create_entries_table
      create_articles_table
    end

    def teardown
      conn.drop_table "cid_accounts"
      conn.drop_table "cid_entries"
      conn.drop_table "cid_articles"
    end

    # --- Basic ID generation -----------------------------------------------

    def test_generates_id_on_create
      account = CidTestModels::Account.create!(name: "Alice")

      refute_nil account.id
    end

    def test_generated_id_starts_with_prefix
      account = CidTestModels::Account.create!(name: "Alice")

      assert_match(/\Aacc_/, account.id)
    end

    def test_generated_id_random_part_has_correct_default_length
      account = CidTestModels::Account.create!(name: "Alice")
      random_part = account.id.split("_", 2).last

      assert_equal 16, random_part.length
    end

    def test_generated_ids_are_unique
      ids = Array.new(50) { CidTestModels::Account.create!(name: "test").id }

      assert_equal ids.uniq.length, ids.length
    end

    def test_does_not_overwrite_an_existing_id
      account = CidTestModels::Account.new(name: "Bob", id: "custom_preset_id")
      account.save!

      assert_equal "custom_preset_id", account.id
    end

    # --- Custom size ---------------------------------------------------------

    def test_custom_size_is_respected
      # Use a fresh AR::Base subclass so it carries no inherited before_create callbacks.
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "cid_accounts"
        cid "acc", size: 8
      end
      record = klass.create!(name: "Small")

      assert_equal 8, record.id.split("_", 2).last.length
    end

    # --- Custom column (name:) -----------------------------------------------

    def test_custom_column_generates_slug
      article = CidTestModels::Article.create!(name: "Hello World")

      refute_nil article.slug
      assert_match(/\Aart_/, article.slug)
    end

    def test_custom_column_random_part_has_correct_length
      article = CidTestModels::Article.create!(name: "Hello World")
      random_part = article.slug.split("_", 2).last

      assert_equal 10, random_part.length
    end

    def test_custom_column_integer_pk_is_auto_assigned_by_db
      article = CidTestModels::Article.create!(name: "Hello")

      assert_kind_of Integer, article.id, "Expected integer pk, got #{article.id.inspect}"
    end

    def test_custom_column_does_not_overwrite_pre_set_value
      article = CidTestModels::Article.new(name: "Hello", slug: "art_preset")
      article.save!

      assert_equal "art_preset", article.slug
    end

    # --- Related model (shared prefix) ---------------------------------------

    def test_related_id_embeds_parent_prefix
      account = CidTestModels::Account.create!(name: "Workspace")
      shared  = account.id.split("_", 2).last.first(8)

      entry = CidTestModels::Entry.create!(name: "Doc", account: account)

      assert_match(/\Aent_/, entry.id)
      assert_includes entry.id, shared,
                      "Expected #{entry.id.inspect} to include shared prefix #{shared.inspect}"
    end

    def test_related_id_total_random_length_is_correct
      account = CidTestModels::Account.create!(name: "Workspace")
      entry   = CidTestModels::Entry.create!(name: "Doc", account: account)
      random_part = entry.id.split("_", 2).last

      assert_equal 24, random_part.length
    end

    def test_related_id_without_parent_generates_random_only
      # When account_id is nil the shared portion falls back to ""
      entry = CidTestModels::Entry.create!(name: "Orphan")

      assert_match(/\Aent_/, entry.id)
      assert_equal 24, entry.id.split("_", 2).last.length
    end

    private

    def conn
      ActiveRecord::Base.connection
    end

    def create_accounts_table
      conn.create_table "cid_accounts", id: :string, force: true do |t|
        t.string :name
      end
    end

    def create_entries_table
      conn.create_table "cid_entries", id: :string, force: true do |t|
        t.string :name
        t.string :account_id
      end
    end

    def create_articles_table
      # Integer PK (default) – cid only manages the :slug column here
      conn.create_table "cid_articles", force: true do |t|
        t.string :name
        t.string :slug
      end
    end
  end
end
