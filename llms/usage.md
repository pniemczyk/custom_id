# CustomId – Usage Patterns for LLMs

> Concrete, copy-pasteable examples covering every supported scenario.
> Optimised for LLM code generation – each section is self-contained.

---

## 1. Installation

```bash
# Gemfile
gem "custom_id"

# Terminal
bundle install
rails custom_id:install   # creates config/initializers/custom_id.rb
```

The initializer auto-includes `CustomId::Concern` into every `ActiveRecord::Base`
subclass.  No `include` is needed in individual models.

---

## 2. Migration – string primary key

Always declare the id column as `:string` for tables where `cid` manages the
primary key.

```ruby
class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users, id: :string do |t|
      t.string :name, null: false
      t.string :email, null: false, index: { unique: true }
      t.timestamps
    end
  end
end
```

**Do not** set a `default:` on the id column – the gem handles that.

---

## 3. Basic model – default primary key

```ruby
class User < ApplicationRecord
  cid "usr"
end

# Result:
user = User.create!(name: "Alice", email: "alice@example.com")
user.id  # => "usr_7xKmN2pQaBcDeFgH"  (16 random Base58 chars after "usr_")
```

The ID format is always `"#{prefix}_#{random}"` where `random` is `size`
Base58 characters long.

---

## 4. Custom size

```ruby
class ApiKey < ApplicationRecord
  cid "key", size: 32
end

ApiKey.create!.id  # => "key_<32 Base58 chars>"
```

`size` controls the length of the random portion only, not the total ID length.
Total length = `prefix.length + 1 + size`.

---

## 5. Non-primary-key column (`name:`)

Use when you want a generated reference code in a non-PK column.  The primary
key can remain an integer or UUID.

**Migration:**

```ruby
class AddSlugToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :slug, :string
    add_index  :articles, :slug, unique: true
  end
end
```

**Model:**

```ruby
class Article < ApplicationRecord
  # id is a regular integer PK managed by the DB
  cid "art", name: :slug, size: 12
end

article = Article.create!(title: "Hello World")
article.id    # => 1  (integer)
article.slug  # => "art_aBcDeFgHiJkL"
```

**Skipping generation** – pre-set the attribute before save:

```ruby
Article.create!(title: "Custom slug", slug: "art_my_special_code")
# slug will NOT be overwritten because it is not nil
```

---

## 6. Embedding parent ID characters (`related:`)

Visually embeds the first N characters of a parent model's random portion into
the child's ID.  Useful for traceability – you can tell which workspace a
document belongs to just by looking at its ID.

**Models:**

```ruby
class Workspace < ApplicationRecord
  cid "wsp"
end

class Document < ApplicationRecord
  belongs_to :workspace
  # Borrow first 6 chars of workspace's random portion; total random = 22
  cid "doc", size: 22, related: { workspace: 6 }
end
```

**Migration for Document:**

```ruby
create_table :documents, id: :string do |t|
  t.string :title, null: false
  t.string :workspace_id, null: false
  t.timestamps
end
```

**Usage:**

```ruby
workspace = Workspace.create!(name: "Acme")
workspace.id  # => "wsp_ABCDEF..."

doc = Document.create!(title: "Spec", workspace: workspace)
doc.id  # => "doc_ABCDEF<16 random chars>"
#                  ^^^^^^ first 6 chars of workspace's random portion
```

**Constraint:** `size` must be strictly greater than the borrowed char count.
`cid "doc", size: 6, related: { workspace: 6 }` raises `ArgumentError`.

**Nil parent:** if the foreign key is `nil` at create time, the shared portion
falls back to `""` and the full `size` is random.

---

## 7. `related:` key must match the `belongs_to` name

```ruby
belongs_to :user            → related: { user: 8 }       ✓
belongs_to :created_by_user → related: { created_by_user: 8 }  ✓
belongs_to :user, foreign_key: :author_id → related: { user: 8 }  ✓
                                            # gem resolves FK via reflection
```

---

## 8. Multiple `cid` calls on one model

Each call registers an independent `before_create` callback.  Use this to
manage multiple string columns:

```ruby
class Contract < ApplicationRecord
  cid "ctr"               # manages :id
  cid "ref", name: :ref_number, size: 8   # manages :ref_number column
end
```

**Warning:** calling `cid` twice for the **same column** on the same class
stacks two callbacks; the second one will always skip because the first already
set the value.  Don't do this.

---

## 9. Manual include (without the Rails initializer)

For non-Rails setups or for a single model:

```ruby
require "custom_id"

class MyModel < ActiveRecord::Base
  include CustomId::Concern
  cid "my"
end
```

---

## 10. Database trigger alternative (`DbExtension`)

Use when IDs must be generated even for raw SQL inserts (bulk imports, ETL).
Supports **PostgreSQL 9.6+**, **MySQL 5.7+**, and **SQLite 3.0+**.

### 10a. PostgreSQL

**Requires the `pgcrypto` extension.**

```bash
# Enable pgcrypto via rake task (once per database)
rails custom_id:db:enable_pgcrypto
# or for a specific database in a multi-database app:
rails "custom_id:db:enable_pgcrypto[postgres]"
```

Or in a migration:

```ruby
class EnablePgcrypto < ActiveRecord::Migration[8.0]
  def up   = enable_extension "pgcrypto"
  def down = disable_extension "pgcrypto"
end
```

**Install trigger in the same migration as table creation:**

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

PostgreSQL returns the generated PK via `RETURNING "id"`, so the ActiveRecord
object has the correct `id` after `create` without any extra work.

### 10b. MySQL – always pair with `cid` on the model

**⚠ Important:** MySQL's `LAST_INSERT_ID()` returns `0` for
non-`AUTO_INCREMENT` columns.  After an AR `create` that leaves `id` blank,
Rails reads back `0` even though the DB row has the correct trigger-generated
value.

**Required pattern:** declare `cid` on the model alongside the trigger.

```ruby
# model – cid generates id in Ruby before INSERT
class Order < ApplicationRecord
  cid "ord"
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

With `cid` on the model, the INSERT includes `id` in the column list, the
trigger's `IF NEW.id IS NULL` guard is false (no-op), and AR has the correct
ID. The trigger still fires for raw SQL inserts that bypass ActiveRecord.

The rake task `custom_id:db:add_trigger` prints a reminder when targeting MySQL:

```
  warn       MySQL: pair this trigger with `cid "ord"` on the model.
```

### 10c. SQLite

SQLite uses two strategies automatically selected by `install_trigger!`:

**Nullable / non-PK column** → AFTER INSERT trigger updates the row in place.

**NOT NULL primary key** → BEFORE INSERT + RAISE(IGNORE) pattern:

```ruby
# migration
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

⚠ When the BEFORE INSERT + RAISE(IGNORE) path is used, `RETURNING "id"` on
the outer INSERT returns nothing. The in-memory AR record may have a stale `id`
until reloaded:

```ruby
item = Item.create!(name: "Widget")
item.reload   # fetch the trigger-generated id from the DB
item.id       # => "itm_Ab3xY7…"
```

### 10d. Custom column and size (all adapters)

```ruby
CustomId::DbExtension.install_trigger!(
  connection, :reports,
  prefix: "rpt",
  column: :report_key,   # default: :id
  size:   24             # default: 16
)
```

### 10e. Remove trigger (all adapters)

```ruby
CustomId::DbExtension.uninstall_trigger!(connection, :teams)
CustomId::DbExtension.uninstall_trigger!(connection, :reports, column: :report_key)
```

### 10f. Check adapter support

```ruby
CustomId::DbExtension.supported?(ActiveRecord::Base.connection)  # => true/false
```

---

## 11. Rails installer rake tasks

```bash
rails custom_id:install    # create config/initializers/custom_id.rb
rails custom_id:uninstall  # remove  config/initializers/custom_id.rb
```

The installed file contains:

```ruby
# frozen_string_literal: true
ActiveSupport.on_load(:active_record) do
  include CustomId::Concern
end
```

---

## 12. Complete working example

```ruby
# db/migrate/..._create_workspace_documents.rb
class CreateWorkspaceDocuments < ActiveRecord::Migration[7.1]
  def change
    create_table :workspaces, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :documents, id: :string do |t|
      t.string  :title,        null: false
      t.string  :workspace_id, null: false, index: true
      t.string  :slug,                      index: { unique: true }
      t.timestamps
    end
  end
end

# app/models/workspace.rb
class Workspace < ApplicationRecord
  has_many :documents
  cid "wsp"
end

# app/models/document.rb
class Document < ApplicationRecord
  belongs_to :workspace
  cid "doc", size: 24, related: { workspace: 6 }
  cid "dsl", name: :slug, size: 10
end

# Usage in console / specs
workspace = Workspace.create!(name: "Acme Corp")
# workspace.id => "wsp_AbCdEf1234567890"

doc = Document.create!(title: "Roadmap", workspace:)
# doc.id   => "doc_AbCdEf<18 random chars>"  (shares "AbCdEf" with workspace)
# doc.slug => "dsl_<10 random chars>"
```

---

## 13. Error reference

| Error | Message | Cause | Fix |
|-------|---------|-------|-----|
| `ArgumentError` | `size (N) must be greater than the number of shared characters (M)` | `size <= chars_to_borrow` in `related:` | Increase `size` |
| `NotImplementedError` | `CustomId::DbExtension does not support …` | `DbExtension` called on an unsupported adapter | Supported: PG, MySQL, SQLite |
| `NotImplementedError` | `The pgcrypto PostgreSQL extension is required but not enabled. Run: rails custom_id:db:enable_pgcrypto` | pgcrypto missing | Run the rake task or add migration |
| `ActiveRecord::NotNullViolation` | `NOT NULL constraint failed: table.id` | String PK table, `cid` callback not firing | Verify include / table schema |
| `id = "0"` after `Model.create` (MySQL) | *(no exception)* | `LAST_INSERT_ID()` returns 0 for string PKs | Add `cid "prefix"` to the model |

---

## 14. DB-extension rake tasks

These tasks let you install and remove `CustomId::DbExtension` objects without
writing migration code.  They wrap the `DbExtension` class methods and require
a live database connection (`:environment` task).

All tasks accept an optional `DATABASE` positional argument that targets a
named database from `database.yml`.  Omit it to use the default connection.

**Enable pgcrypto (PostgreSQL only – once per database)**

```bash
rails custom_id:db:enable_pgcrypto
rails "custom_id:db:enable_pgcrypto[postgres]"    # multi-database
#   create     pgcrypto extension
```

**Install the shared Base58 function (PG and MySQL)**

```bash
rails custom_id:db:install_function
rails "custom_id:db:install_function[postgres]"   # multi-database
#   create     custom_id_base58() function
```

Safe to call multiple times – uses `CREATE OR REPLACE` / `IF NOT EXISTS`.

**Remove the shared Base58 function**

```bash
rails custom_id:db:uninstall_function
rails "custom_id:db:uninstall_function[postgres]" # multi-database
#   remove     custom_id_base58() function
```

**Add a BEFORE INSERT trigger to a table**

```bash
# Minimal – column defaults to :id, size defaults to 16
rails "custom_id:db:add_trigger[users,usr]"
#   create     trigger on users.id (prefix=usr, size=16)

# Custom column and size
rails "custom_id:db:add_trigger[reports,rpt,report_key,24]"
#   create     trigger on reports.report_key (prefix=rpt, size=24)

# Multi-database (skip optional args with empty positions)
rails "custom_id:db:add_trigger[users,usr,,,postgres]"
rails "custom_id:db:add_trigger[reports,rpt,report_key,24,postgres]"
```

Arguments (positional, comma-separated inside brackets):

| Position | Name | Default | Notes |
|----------|------|---------|-------|
| 1 | `table` | required | Table name |
| 2 | `prefix` | required | ID prefix string |
| 3 | `column` | `id` | Column to populate |
| 4 | `size` | `16` | Random portion length |
| 5 | `database` | *(default)* | Named DB from `database.yml` |

**MySQL warning:** when targeting a MySQL connection the task also prints:

```
  warn       MySQL: pair this trigger with `cid "prefix"` on the model.
             Without cid, ActiveRecord reads LAST_INSERT_ID() = 0 for string PKs
             and nil for other trigger-managed columns after INSERT.
             The trigger still fires for raw SQL inserts that bypass ActiveRecord.
```

**Remove a BEFORE INSERT trigger from a table**

```bash
rails "custom_id:db:remove_trigger[users]"
#   remove     trigger on users.id

rails "custom_id:db:remove_trigger[reports,report_key]"
#   remove     trigger on reports.report_key

rails "custom_id:db:remove_trigger[users,,postgres]"   # multi-database
```

**Error behaviour**

If pgcrypto is missing on PostgreSQL:

```
  error: The pgcrypto PostgreSQL extension is required but not enabled.
         Run: rails custom_id:db:enable_pgcrypto
         or add enable_extension "pgcrypto" to a migration.
```

If an unknown database name is passed:

```
  error: Unknown database "bad_name". Available for "development": primary, postgres, mysql
```
