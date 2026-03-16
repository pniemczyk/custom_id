# frozen_string_literal: true

# Example: embedding parent ID characters into child IDs using related:
# Useful for traceability — you can tell which parent a record belongs to
# just by inspecting its ID.

# ─── Migrations ─────────────────────────────────────────────────────────────

class CreateWorkspaceDocuments < ActiveRecord::Migration[7.1]
  def change
    create_table :workspaces, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :documents, id: :string do |t|
      t.string :title,        null: false
      t.string :workspace_id, null: false, index: true
      t.string :slug,                      index: { unique: true }
      t.timestamps
    end
  end
end

# ─── Models ─────────────────────────────────────────────────────────────────

class Workspace < ApplicationRecord
  has_many :documents
  cid "wsp"
end

class Document < ApplicationRecord
  belongs_to :workspace

  # Borrow first 6 chars of workspace's random portion.
  # Total random portion = 22, of which 6 are shared + 16 are random.
  cid "doc", size: 22, related: { workspace: 6 }

  # A second, independent slug column — no shared chars
  cid "dsl", name: :slug, size: 10
end

# ─── Usage ──────────────────────────────────────────────────────────────────

workspace = Workspace.create!(name: "Acme Corp")
workspace.id  # => "wsp_AbCdEf1234567890"
#                         ^^^^^^ random portion starts here

doc = Document.create!(title: "Roadmap", workspace: workspace)
doc.id    # => "doc_AbCdEf<16 random chars>"
#                    ^^^^^^ matches workspace's first 6 random chars
doc.slug  # => "dsl_<10 random chars>"

# ─── related: key must be the association name ──────────────────────────────

class Invoice < ApplicationRecord
  belongs_to :customer
  cid "inv", size: 20, related: { customer: 4 }
  # related: { customer: 4 } ← correct: matches the belongs_to name
  # related: { customer_id: 4 } ← WRONG: that's the FK column, not the association
end

# ─── Custom FK via belongs_to option ────────────────────────────────────────

class Event < ApplicationRecord
  belongs_to :author, class_name: "User", foreign_key: :user_id
  cid "evt", size: 20, related: { author: 4 }
  # related: key is "author" — the association name, not "user" or "user_id"
end

# ─── Nil parent at create time ──────────────────────────────────────────────

doc_no_workspace = Document.new(title: "Orphan")
doc_no_workspace.save!(validate: false)
# workspace_id is nil → shared_chars falls back to "" → full 22 chars are random
doc_no_workspace.id  # => "doc_<22 random chars>"

# ─── ArgumentError guard ────────────────────────────────────────────────────

# This raises ArgumentError at create time (not at class definition):
#   cid "doc", size: 6, related: { workspace: 6 }
# Because size (6) must be strictly greater than chars_to_borrow (6).
# Fix: increase size or reduce borrowed chars.
#   cid "doc", size: 10, related: { workspace: 6 }  ← ok
