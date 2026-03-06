# CustomId – Architecture Overview

> Intended audience: LLMs and AI agents that need a precise mental model of
> the gem internals before generating code.

---

## Purpose

`custom_id` gives ActiveRecord models human-readable, prefixed string IDs in
the style popularised by Stripe:

```
usr_7xKmN2pQaBcDeFgH   ← "usr" prefix + 16 Base58 chars
doc_ABCDEF7xKmN2pQaBcD ← "doc" prefix + 6 shared chars from parent + 18 random
```

IDs are generated in Ruby inside a `before_create` callback.  An optional
database-trigger alternative (`CustomId::DbExtension`) produces identical IDs
at the database level and supports PostgreSQL, MySQL, and SQLite.

---

## Module structure

```
CustomId                          (top-level namespace, lib/custom_id.rb)
├── Concern                       (lib/custom_id/concern.rb)
│   └── class_methods { cid }    → registers before_create on the calling model
├── Installer                     (lib/custom_id/installer.rb)
│   ├── .install!(root)          → writes config/initializers/custom_id.rb
│   └── .uninstall!(root)        → removes the initializer file
├── Railtie < Rails::Railtie     (lib/custom_id/railtie.rb)
│   └── rake_tasks { load rake } → exposes all custom_id:* rake tasks
├── DbExtension                   (lib/custom_id/db_extension.rb)
│   ├── .supported?(connection)          → true for pg/mysql/sqlite adapters
│   ├── .install_generate_function!      → creates custom_id_base58() PG/MySQL function
│   ├── .uninstall_generate_function!    → drops the PG/MySQL function
│   ├── .install_trigger!        → writes trigger (PG/MySQL/SQLite)
│   └── .uninstall_trigger!      → drops trigger
└── Error < StandardError
```

---

## ID generation algorithm (Ruby path)

```
before_create callback fires
  │
  ├─ send(name).nil? → false → skip (ID already set by caller)
  │
  └─ true → generate
       │
       ├─ resolve shared_chars
       │    └─ related.present?
       │         ├─ no  → shared = ""
       │         └─ yes → reflection = self.class.reflections[assoc_name]
       │                   foreign_key = reflection.foreign_key
       │                   ref_id = read_attribute(foreign_key)
       │                   shared = ref_id.split("_", 2).last.first(borrow_count)
       │                             or "" if ref_id is nil
       │
       └─ collision-resistant loop
            generate = "#{prefix}_#{shared}#{SecureRandom.base58(size - shared.length)}"
            send(:"#{name}=", generate)
            break unless Model.exists?(name => generate)
```

### Complexity notes

- For the primary-key column (`name: :id`) the `exists?` check hits the PK
  index – O(log n), fast even for large tables.
- For non-PK columns (`name: :slug`) an index on that column is recommended.
- Base58 alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`
  (58 chars, no `0`, `O`, `I`, `l` to avoid visual ambiguity).
- With `size: 16` the collision probability at 1 million rows is ≈ 5 × 10⁻⁹.

---

## ID generation algorithm (database trigger paths)

### PostgreSQL

```
BEFORE INSERT trigger fires on each row
  │
  └─ IF NEW.column IS NULL
       NEW.column := prefix || '_' || custom_id_base58(size)

custom_id_base58(n):
  rand_bytes := gen_random_bytes(n)   -- pgcrypto extension (required)
  FOR i IN 0..n-1:
    result += chars[ get_byte(rand_bytes, i) % 58 ]
  RETURN result
```

PostgreSQL uses two objects per table:
- a **trigger function** `#{table}_#{column}_custom_id()` (PL/pgSQL)
- a **BEFORE INSERT trigger** `#{table}_#{column}_before_insert_custom_id`

The shared `custom_id_base58()` function is created once per database.
Requires the `pgcrypto` extension (`enable_extension "pgcrypto"` or
`rails custom_id:db:enable_pgcrypto`).

### MySQL

```
BEFORE INSERT trigger fires on each row
  │
  └─ IF NEW.column IS NULL
       SET NEW.column = CONCAT(prefix, '_', custom_id_base58(size))

custom_id_base58(n):
  WHILE i < n:
    result += SUBSTR(chars, (ORD(RANDOM_BYTES(1)) % 58) + 1, 1)
  RETURN result
```

MySQL uses a single `BEFORE INSERT` trigger per table and a shared
`custom_id_base58()` stored function. Both DROP and CREATE are sent as
separate `connection.execute` calls because `mysql2`/`trilogy` reject
multi-statement strings.

**⚠ MySQL + ActiveRecord string PKs:** MySQL's `LAST_INSERT_ID()` returns `0`
for non-`AUTO_INCREMENT` columns. After an AR `create` without an explicit
`id`, the in-memory record has `id = "0"` even though the DB row is correct.
**Fix:** also declare `cid` on the model so AR generates the ID before INSERT.

### SQLite

SQLite has two strategies depending on the column type:

**Non-PK or nullable column → AFTER INSERT trigger**
```
AFTER INSERT trigger updates the row in-place using rowid.
```

**NOT NULL primary key → BEFORE INSERT + RAISE(IGNORE)**
```
BEFORE INSERT trigger fires:
  1. Generates ID with substr/abs(random())/% 58 inline expressions
  2. Inner INSERT with generated ID (WHEN NEW.id IS NULL guard prevents recursion)
  3. SELECT RAISE(IGNORE) abandons the outer NULL-id statement before
     SQLite evaluates the NOT NULL constraint
```

Note: when RAISE(IGNORE) abandons the outer INSERT, `RETURNING "id"` returns
nothing. Call `record.reload` after `create` to read the correct ID from the DB.

Shared-character support is **not** available in any trigger path because
cross-table reads inside a trigger are a concurrency anti-pattern.

---

## ActiveSupport integration

### Auto-include mechanism

The gem ships a Railtie.  When a developer runs `rails custom_id:install`, the
Installer writes:

```ruby
# config/initializers/custom_id.rb
ActiveSupport.on_load(:active_record) do
  include CustomId::Concern
end
```

`ActiveSupport.on_load(:active_record)` defers the `include` until
`ActiveRecord::Base` is fully loaded, preventing load-order issues.  After this
runs, every class that inherits from `ActiveRecord::Base` automatically has the
`cid` class macro available.

### Without the initializer

Include manually in individual models or a base class:

```ruby
class ApplicationRecord < ActiveRecord::Base
  include CustomId::Concern
  primary_abstract_class
end
```

---

## Callback inheritance and STI

`cid "usr"` registers a `before_create` callback on the **class that calls
`cid`**, not on its subclasses.  Because ActiveRecord inherits callbacks,
subclasses in an STI hierarchy will fire the parent's callback – which is
usually correct.

**Pitfall**: if a subclass calls `cid` again with different options, both
callbacks run.  The first one sees `nil` and generates an ID; the second sees a
non-nil value and skips.  Result: only the parent's options take effect.  To
override, either use a fresh non-inheriting class in tests, or avoid double
`cid` calls in the same hierarchy.

---

## Multi-database support (rake tasks)

All `custom_id:db:*` rake tasks accept an optional `DATABASE` positional
argument (last position). It is matched against named database configs in
`database.yml` via `ActiveRecord::Base.configurations.find_db_config`.

A named abstract AR subclass (`CustomId::RakeDbProxy`) is created via
`const_set` and used for the alternate connection.  This avoids replacing the
global default connection and satisfies Rails 7.2+'s requirement that
`establish_connection` only be called on named (non-anonymous) classes.

---

## File inclusion in gem package

```ruby
spec.files = Dir[
  "lib/**/*.rb",
  "lib/tasks/*.rake",
  "llms/**/*.md",    # ← these files ship inside the gem
  "AGENTS.md",
  "CLAUDE.md",
  "README.md",
  "LICENSE.txt",
  "CHANGELOG.md"
]
```

LLM context files ship **inside the released gem** so that tools that install
the gem can serve them as context to AI assistants.

---

## Rake task reference

All `db:*` tasks accept an optional `DATABASE` arg (matches a name from
`database.yml`).  Omit it to use the default connection.

| Task | Depends on | Description |
|------|-----------|-------------|
| `custom_id:install` | — | Delegates to `CustomId::Installer.install!(Rails.root)` |
| `custom_id:uninstall` | — | Delegates to `CustomId::Installer.uninstall!(Rails.root)` |
| `custom_id:db:enable_pgcrypto[DATABASE]` | `:environment` | `CREATE EXTENSION IF NOT EXISTS pgcrypto` on PG connection |
| `custom_id:db:install_function[DATABASE]` | `:environment` | `DbExtension.install_generate_function!(conn)` |
| `custom_id:db:uninstall_function[DATABASE]` | `:environment` | `DbExtension.uninstall_generate_function!(conn)` |
| `custom_id:db:add_trigger[table,prefix,column,size,DATABASE]` | `:environment` | `DbExtension.install_trigger!(conn, ...)` + MySQL warning |
| `custom_id:db:remove_trigger[table,column,DATABASE]` | `:environment` | `DbExtension.uninstall_trigger!(conn, ...)` |

All `db:*` tasks rescue `NotImplementedError` and call `abort` with a
human-readable message when the adapter is not supported.

---

## Testing architecture

| Component | Tool | Database |
|-----------|------|----------|
| Ruby concern | Minitest | SQLite in-memory |
| Installer | Minitest | `Dir.mktmpdir` (filesystem) |
| DB extension – nullable column | Minitest | SQLite in-memory |
| DB extension – NOT NULL PK | Minitest | SQLite in-memory |

`test_helper.rb` boots ActiveRecord against SQLite and calls
`ActiveSupport.on_load(:active_record) { include CustomId::Concern }` to
replicate what the Rails initializer does.

Each test creates its own tables in `setup` and drops them in `teardown`,
providing full isolation without transactions.

PostgreSQL and MySQL paths are not covered by the automated test suite
(they require a live server).  The SQLite tests exercise the same
`install_trigger!` / `uninstall_trigger!` public interface.
