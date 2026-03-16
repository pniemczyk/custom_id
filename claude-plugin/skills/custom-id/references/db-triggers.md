# custom_id — Database Trigger Alternative

Use `CustomId::DbExtension` when IDs must be generated even for raw SQL
inserts that bypass ActiveRecord (bulk imports, ETL pipelines, external tools).

Supports **PostgreSQL 9.6+**, **MySQL 5.7+**, and **SQLite 3.0+**.

---

## When to Use Triggers vs. `cid`

| Approach | Generates ID | Works for raw SQL | AR gets correct ID |
|----------|-------------|-------------------|--------------------|
| `cid` on model | Ruby `before_create` | ✗ (AR only) | ✅ always |
| DB trigger (PG, SQLite) | Database | ✅ | ✅ |
| DB trigger (MySQL) | Database | ✅ | ⚠ requires `cid` too |

---

## PostgreSQL

### Requirements

- `pgcrypto` extension must be enabled (once per database).

### Enable pgcrypto

```bash
# Rake task (recommended — idempotent)
rails custom_id:db:enable_pgcrypto

# For a named database in a multi-db app
rails "custom_id:db:enable_pgcrypto[postgres]"
```

Or in a migration:

```ruby
class EnablePgcrypto < ActiveRecord::Migration[8.0]
  def up   = enable_extension "pgcrypto"
  def down = disable_extension "pgcrypto"
end
```

### Install Trigger in Migration

```ruby
class CreateTeams < ActiveRecord::Migration[7.1]
  def up
    create_table :teams, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end
    CustomId::DbExtension.install_trigger!(connection, :teams, prefix: "tea")
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :teams)
    drop_table :teams
  end
end
```

PostgreSQL uses `RETURNING "id"` so the AR object has the correct `id`
immediately after `create` — no `reload` needed.

---

## MySQL

### ⚠ Always Pair with `cid` on the Model

MySQL's `LAST_INSERT_ID()` returns `0` for non-`AUTO_INCREMENT` columns.
After an AR `create` that leaves `id` blank, Rails reads `"0"` even though
the DB row has the correct trigger-generated value.

**Required pattern:** declare `cid` on the model alongside the trigger.
`cid` generates the ID in Ruby before INSERT. The trigger only fires for
raw SQL inserts that bypass ActiveRecord.

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  cid "ord"   # ← required alongside the MySQL trigger
end
```

```ruby
# migration
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
```

The rake task `custom_id:db:add_trigger` prints a reminder when targeting MySQL:

```
  warn       MySQL: pair this trigger with `cid "ord"` on the model.
```

---

## SQLite

SQLite selects a strategy automatically based on the column type:

- **Nullable or non-PK column** → AFTER INSERT trigger updates the row in place.
- **NOT NULL primary key** → BEFORE INSERT + RAISE(IGNORE) pattern.

### ⚠ RAISE(IGNORE) Requires `reload`

When the BEFORE INSERT + RAISE(IGNORE) path fires (NOT NULL PK), `RETURNING "id"`
on the outer INSERT returns nothing. The in-memory AR record has a stale `id`
until reloaded:

```ruby
item = Item.create!(name: "Widget")
item.reload   # fetch the trigger-generated id
item.id       # => "itm_Ab3xY7…"
```

```ruby
# Migration
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
```

---

## Custom Column and Size (All Adapters)

```ruby
CustomId::DbExtension.install_trigger!(
  connection, :reports,
  prefix: "rpt",
  column: :report_key,   # default: :id
  size:   24             # default: 16
)
```

---

## Remove Trigger

```ruby
CustomId::DbExtension.uninstall_trigger!(connection, :teams)
CustomId::DbExtension.uninstall_trigger!(connection, :reports, column: :report_key)
```

---

## Rake Tasks for Triggers

All `custom_id:db:*` tasks accept an optional `DATABASE` argument (last
positional) to target a named database from `database.yml`.

```bash
# Enable pgcrypto (PostgreSQL only — once per database)
rails custom_id:db:enable_pgcrypto
rails "custom_id:db:enable_pgcrypto[postgres]"

# Install shared Base58 function (PG and MySQL — once per database)
rails custom_id:db:install_function
rails "custom_id:db:install_function[postgres]"

# Remove shared function
rails custom_id:db:uninstall_function

# Add trigger to a table
rails "custom_id:db:add_trigger[users,usr]"
rails "custom_id:db:add_trigger[reports,rpt,report_key,24]"
rails "custom_id:db:add_trigger[users,usr,,,postgres]"         # multi-db

# Remove trigger from a table
rails "custom_id:db:remove_trigger[users]"
rails "custom_id:db:remove_trigger[reports,report_key]"
rails "custom_id:db:remove_trigger[users,,postgres]"           # multi-db
```

### `add_trigger` positional arguments

| Position | Name | Default | Notes |
|----------|------|---------|-------|
| 1 | `table` | required | Table name |
| 2 | `prefix` | required | ID prefix string |
| 3 | `column` | `id` | Column to populate |
| 4 | `size` | `16` | Random portion length |
| 5 | `database` | *(default)* | Named DB from `database.yml` |

---

## Adapter Support Check

```ruby
CustomId::DbExtension.supported?(ActiveRecord::Base.connection)  # => true/false
```

---

## Shared Characters (`related:`) and Triggers

The `related:` parent-embedding feature is **only available in the Ruby path**
(`cid` on the model). Database triggers cannot perform cross-table reads safely
inside a single transaction. If you need parent-embedded IDs, use `cid` on
the model (even if you also have a trigger for raw SQL safety on MySQL).
