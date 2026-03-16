# frozen_string_literal: true

# Example: database trigger setup via CustomId::DbExtension
# Use triggers when IDs must be generated for raw SQL inserts that bypass
# ActiveRecord (bulk imports, ETL, external tools).

# ─── PostgreSQL ──────────────────────────────────────────────────────────────
#
# Requires the pgcrypto extension. Enable it first (once per database):
#   rails custom_id:db:enable_pgcrypto
#
# Or in a migration:
class EnablePgcrypto < ActiveRecord::Migration[8.0]
  def up   = enable_extension "pgcrypto"
  def down = disable_extension "pgcrypto"
end

class CreateTeams < ActiveRecord::Migration[7.1]
  def up
    create_table :teams, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end
    # Install the BEFORE INSERT trigger on teams.id
    CustomId::DbExtension.install_trigger!(connection, :teams, prefix: "tea")
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :teams)
    drop_table :teams
  end
end

# PostgreSQL uses RETURNING "id" — no reload needed.
# Team.create!(name: "Alpha").id  # => "tea_<16 chars>" immediately

# ─── MySQL ───────────────────────────────────────────────────────────────────
#
# ⚠ ALWAYS pair with `cid` on the model for MySQL string PKs.
# MySQL LAST_INSERT_ID() returns 0 for non-AUTO_INCREMENT columns.
# Without `cid`, ActiveRecord reads id = "0" after create.

class Order < ApplicationRecord
  cid "ord"   # ← required: generates ID in Ruby before INSERT
              #   trigger still fires for raw SQL inserts
end

class CreateOrders < ActiveRecord::Migration[8.0]
  def up
    create_table :orders, id: :string do |t|
      t.string :status, null: false
      t.timestamps
    end
    CustomId::DbExtension.install_trigger!(connection, :orders, prefix: "ord")
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :orders)
    drop_table :orders
  end
end

# ─── SQLite ──────────────────────────────────────────────────────────────────
#
# SQLite with NOT NULL primary key uses BEFORE INSERT + RAISE(IGNORE).
# The outer INSERT is abandoned; RETURNING returns nothing.
# Call .reload to get the correct id.

class CreateItems < ActiveRecord::Migration[8.0]
  def up
    create_table :items, id: :string do |t|
      t.string :name
    end
    CustomId::DbExtension.install_trigger!(connection, :items, prefix: "itm")
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :items)
    drop_table :items
  end
end

# item = Item.create!(name: "Widget")
# item.reload   # ← required for SQLite NOT NULL PK trigger path
# item.id       # => "itm_Ab3xY7…"

# ─── Custom column and size (all adapters) ───────────────────────────────────

class CreateReports < ActiveRecord::Migration[8.0]
  def up
    create_table :reports do |t|   # integer PK
      t.string :report_key, index: { unique: true }
      t.string :title
      t.timestamps
    end
    CustomId::DbExtension.install_trigger!(
      connection, :reports,
      prefix: "rpt",
      column: :report_key,
      size:   24
    )
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :reports, column: :report_key)
    drop_table :reports
  end
end

# ─── Checking adapter support ────────────────────────────────────────────────

CustomId::DbExtension.supported?(ActiveRecord::Base.connection)  # => true/false