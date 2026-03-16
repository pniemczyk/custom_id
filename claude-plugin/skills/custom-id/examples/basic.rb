# frozen_string_literal: true

# Example: basic custom_id usage in ActiveRecord models
# Assumes `rails custom_id:install` has been run.

# ─── Migration ──────────────────────────────────────────────────────────────

class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users, id: :string do |t|
      t.string :name,  null: false
      t.string :email, null: false, index: { unique: true }
      t.timestamps
    end
  end
end

# ─── Model — default PK ─────────────────────────────────────────────────────

class User < ApplicationRecord
  cid "usr"
end

user = User.create!(name: "Alice", email: "alice@example.com")
user.id  # => "usr_7xKmN2pQaBcDeFgH"

# ─── Model — custom size ────────────────────────────────────────────────────

class ApiKey < ApplicationRecord
  cid "key", size: 32
end

# Migration
# create_table :api_keys, id: :string do |t|
#   t.string :name
#   t.timestamps
# end

ApiKey.create!.id  # => "key_<32 Base58 chars>"

# ─── Model — non-PK column ──────────────────────────────────────────────────

class Article < ApplicationRecord
  # id is a regular integer PK managed by the DB
  cid "art", name: :slug, size: 12
end

# Migration
# add_column :articles, :slug, :string
# add_index  :articles, :slug, unique: true

article = Article.create!(title: "Hello World")
article.id    # => 1
article.slug  # => "art_aBcDeFgHiJkL"

# Pre-set the attribute to skip generation
Article.create!(title: "Fixed", slug: "art_my_special_code")
# slug is NOT overwritten

# ─── Model — multiple cid calls (different columns) ─────────────────────────

class Contract < ApplicationRecord
  cid "ctr"                              # manages :id
  cid "ref", name: :ref_number, size: 8  # manages :ref_number
end

# Migration
# create_table :contracts, id: :string do |t|
#   t.string :ref_number, index: { unique: true }
#   t.timestamps
# end

c = Contract.create!
c.id          # => "ctr_<16 chars>"
c.ref_number  # => "ref_<8 chars>"

# ─── Finding by string ID ────────────────────────────────────────────────────

User.find("usr_7xKmN2pQaBcDeFgH")
User.find_by(id: "usr_7xKmN2pQaBcDeFgH")
User.where(id: ["usr_abc", "usr_def"])

# ─── Seeding / importing with known IDs ─────────────────────────────────────

User.create!(id: "usr_legacy_abc123", name: "Legacy User")
# id is preserved — cid callback skips when value already set
