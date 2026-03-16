# frozen_string_literal: true

# Example: Minitest patterns for models using custom_id
# The test suite uses SQLite in-memory — create and drop tables in setup/teardown.

require "minitest/autorun"
require "active_record"
require "custom_id"

# ─── Test helper setup (mirrors gem's own test_helper.rb) ───────────────────

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveSupport.on_load(:active_record) { include CustomId::Concern }

# ─── Model with default PK ──────────────────────────────────────────────────

class UserCidTest < Minitest::Test
  def setup
    ActiveRecord::Schema.define do
      create_table :users, id: :string, force: true do |t|
        t.string :name, null: false
      end
    end

    @user_class = Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      cid "usr"
    end
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:users, if_exists: true)
  end

  def test_generates_prefixed_id_on_create
    user = @user_class.create!(name: "Alice")
    assert_match(/\Ausr_[1-9A-HJ-NP-Za-km-z]{16}\z/, user.id)
  end

  def test_id_starts_with_correct_prefix
    user = @user_class.create!(name: "Bob")
    assert user.id.start_with?("usr_")
  end

  def test_each_record_gets_a_unique_id
    ids = 10.times.map { @user_class.create!(name: "User").id }
    assert_equal ids.uniq.length, ids.length
  end

  def test_does_not_overwrite_preset_id
    user = @user_class.create!(id: "usr_preset_abc", name: "Preset")
    assert_equal "usr_preset_abc", user.id
  end
end

# ─── Model with custom size ──────────────────────────────────────────────────

class ApiKeyCidTest < Minitest::Test
  def setup
    ActiveRecord::Schema.define do
      create_table :api_keys, id: :string, force: true do |t|
        t.string :name
      end
    end

    @key_class = Class.new(ActiveRecord::Base) do
      self.table_name = "api_keys"
      cid "key", size: 32
    end
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:api_keys, if_exists: true)
  end

  def test_random_portion_is_correct_length
    key = @key_class.create!
    # total = "key_".length + 32 = 36
    assert_equal 36, key.id.length
  end
end

# ─── Model with non-PK column ────────────────────────────────────────────────

class ArticleSlugTest < Minitest::Test
  def setup
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|   # integer PK
        t.string :title
        t.string :slug
      end
    end

    @article_class = Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      cid "art", name: :slug, size: 12
    end
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:articles, if_exists: true)
  end

  def test_slug_generated_on_create
    article = @article_class.create!(title: "Hello")
    assert_match(/\Aart_[1-9A-HJ-NP-Za-km-z]{12}\z/, article.slug)
  end

  def test_integer_id_unaffected
    article = @article_class.create!(title: "Hello")
    assert_kind_of Integer, article.id
  end

  def test_preset_slug_not_overwritten
    article = @article_class.create!(title: "Custom", slug: "art_my_code")
    assert_equal "art_my_code", article.slug
  end
end

# ─── Model with related: (parent-embedded chars) ────────────────────────────

class RelatedCidTest < Minitest::Test
  def setup
    ActiveRecord::Schema.define do
      create_table :workspaces, id: :string, force: true do |t|
        t.string :name
      end
      create_table :documents, id: :string, force: true do |t|
        t.string :title
        t.string :workspace_id
      end
    end

    ws_class = Class.new(ActiveRecord::Base) do
      self.table_name = "workspaces"
      cid "wsp"
    end
    Object.const_set(:TestWorkspace, ws_class) unless defined?(TestWorkspace)

    doc_class = Class.new(ActiveRecord::Base) do
      self.table_name = "documents"
      belongs_to :test_workspace, foreign_key: :workspace_id
      cid "doc", size: 22, related: { test_workspace: 6 }
    end
    Object.const_set(:TestDocument, doc_class) unless defined?(TestDocument)

    @workspace = TestWorkspace.create!(name: "Acme")
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:documents, if_exists: true)
    ActiveRecord::Base.connection.drop_table(:workspaces, if_exists: true)
    Object.send(:remove_const, :TestDocument) if defined?(TestDocument)
    Object.send(:remove_const, :TestWorkspace) if defined?(TestWorkspace)
  end

  def test_document_shares_workspace_prefix
    doc = TestDocument.create!(title: "Spec", test_workspace: @workspace)
    ws_random = @workspace.id.split("_", 2).last
    assert doc.id.start_with?("doc_#{ws_random.first(6)}")
  end

  def test_document_id_total_random_length
    doc = TestDocument.create!(title: "Spec", test_workspace: @workspace)
    random_portion = doc.id.split("_", 2).last
    assert_equal 22, random_portion.length
  end
end

# ─── ArgumentError for invalid related: size ─────────────────────────────────

class RelatedSizeValidationTest < Minitest::Test
  def setup
    ActiveRecord::Schema.define do
      create_table :things, id: :string, force: true do |t|
        t.string :owner_id
      end
      create_table :owners, id: :string, force: true
    end

    owner_class = Class.new(ActiveRecord::Base) { self.table_name = "owners"; cid "own" }
    Object.const_set(:TestOwner, owner_class) unless defined?(TestOwner)

    thing_class = Class.new(ActiveRecord::Base) do
      self.table_name = "things"
      belongs_to :test_owner, foreign_key: :owner_id
      cid "thn", size: 4, related: { test_owner: 4 }  # size == borrow → invalid
    end
    Object.const_set(:TestThing, thing_class) unless defined?(TestThing)

    @owner = TestOwner.create!
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:things, if_exists: true)
    ActiveRecord::Base.connection.drop_table(:owners, if_exists: true)
    Object.send(:remove_const, :TestThing) if defined?(TestThing)
    Object.send(:remove_const, :TestOwner) if defined?(TestOwner)
  end

  def test_raises_argument_error_when_size_equals_borrow_count
    assert_raises(ArgumentError) { TestThing.create!(test_owner: @owner) }
  end
end
