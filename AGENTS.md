# CustomId – Agent Guide

> Concise reference for AI coding agents working **on** the `custom_id` gem or
> **with** it inside a host Rails application.
>
> For end-user documentation see `README.md`.
> For LLM-optimised usage patterns see `llms/usage.md`.
> For architecture details see `llms/overview.md`.

---

## What this gem does

`custom_id` generates unique, prefixed, Base58 string IDs for ActiveRecord
models – e.g. `"usr_7xKmN2pQ…"` – via a single class-macro `cid`.

---

## Quick integration checklist (host app)

```bash
bundle add custom_id
rails custom_id:install      # creates config/initializers/custom_id.rb
```

After that every model inherits the `cid` macro automatically.  No `include`
needed.

---

## `cid` macro signature

```ruby
cid(prefix, size: 16, related: {}, name: :id)
```

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `prefix` | `String \| Symbol` | required | Prepended before `_`. Stored verbatim in the ID. |
| `size` | `Integer` | `16` | Length of the random Base58 portion **after** the `_` separator. |
| `related` | `Hash{Symbol => Integer}` | `{}` | Single-entry: `{ association_name => chars_to_borrow }`. Borrows the first N characters from the parent's ID random portion. |
| `name` | `Symbol` | `:id` | Column to populate. Use any string column, not just the primary key. |

Generated ID format: `"#{prefix}_#{shared_chars}#{random_chars}"`
where `shared_chars.length + random_chars.length == size`.

---

## Rules agents must follow

### Always
- Call `cid` **after** the `belongs_to` declaration when using `related:`.
- Use `id: :string` in migrations for tables where `cid` manages the primary key.
- Match the `related:` key to the exact `belongs_to` association name (`:user`,
  not `:user_id`).
- Ensure `size > chars_to_borrow` (otherwise an `ArgumentError` is raised at
  record creation time).
- **MySQL + DB trigger on string PK:** always declare `cid` on the model as
  well. MySQL's `LAST_INSERT_ID()` returns `0` for non-`AUTO_INCREMENT` columns,
  so ActiveRecord cannot read back the trigger-generated string PK. `cid`
  generates the ID in Ruby before INSERT so Rails includes it in the column list.
  The trigger then acts only as a safety net for raw SQL inserts.

### Never
- Set `default:` on the id column in migrations – the gem handles generation.
- Call `cid` more than once per column on the same class (multiple `cid` calls
  on a class are cumulative callbacks; only the first one that finds a nil value
  will fire, but it is confusing).
- On **PostgreSQL or SQLite**, mix `CustomId::Concern` with a DB trigger on the
  same table/column – pick one approach. On **MySQL**, combining both is required
  for correct ActiveRecord behaviour (see above).

---

## Gem internals (working on the gem itself)

### Module map

| File | Responsibility |
|------|----------------|
| `lib/custom_id/concern.rb` | `cid` class macro + private `before_create` helpers |
| `lib/custom_id/installer.rb` | Creates/removes `config/initializers/custom_id.rb` |
| `lib/custom_id/railtie.rb` | Registers all `custom_id:*` rake tasks |
| `lib/custom_id/db_extension.rb` | PostgreSQL, MySQL, and SQLite trigger-based alternative |
| `lib/tasks/custom_id.rake` | Rake task implementations (install/uninstall + db sub-namespace) |

### Rake task reference

All `custom_id:db:*` tasks accept an optional `DATABASE` positional argument
that selects a named database from `database.yml` (multi-database Rails apps).
Omit it to use the default connection.

| Task | Args | Description |
|------|------|-------------|
| `custom_id:install` | — | Create `config/initializers/custom_id.rb` |
| `custom_id:uninstall` | — | Remove `config/initializers/custom_id.rb` |
| `custom_id:db:enable_pgcrypto` | `[DATABASE]` | Enable `pgcrypto` PG extension (required before PG triggers) |
| `custom_id:db:install_function` | `[DATABASE]` | Install shared `custom_id_base58()` function (PG/MySQL) |
| `custom_id:db:uninstall_function` | `[DATABASE]` | Remove the shared function (PG/MySQL) |
| `custom_id:db:add_trigger` | `[table,prefix,column,size,DATABASE]` | Install BEFORE INSERT trigger; column defaults to `id`, size to `16` |
| `custom_id:db:remove_trigger` | `[table,column,DATABASE]` | Remove BEFORE INSERT trigger from a table |

The `custom_id:db:*` tasks require the `:environment` task (Rails app booted).

### Test suite

```bash
bundle exec rake test     # Minitest with SQLite in-memory
bundle exec rubocop       # RuboCop linting
bundle exec rake          # Both (default task)
```

Tests live in `test/custom_id/`.  Each test class uses `setup`/`teardown` to
create and drop SQLite tables so tests are fully isolated.

### Adding a new test

1. Extend `Minitest::Test` inside the `CustomId` module namespace.
2. Name the file `test/custom_id/<feature>_test.rb` (picked up by Rakefile glob).
3. Create tables in `setup`, drop them in `teardown`.

### Dependency notes

- `SecureRandom.base58` is provided by `active_support/core_ext/securerandom` –
  already required by `concern.rb`.
- `related:` resolution uses `ActiveRecord::Reflection` – works only on proper
  AR models with `belongs_to` defined.

---

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `NOT NULL constraint failed: table.id` | String PK table, `cid` not firing | Verify `before_create` callback is registered; check `name:` param |
| ID generated without shared prefix | `belongs_to` missing or `account_id` is nil at create time | Ensure parent is persisted and passed before child is created |
| `ArgumentError: size must be greater than shared chars` | `size <= chars_to_borrow` | Increase `size` or reduce borrowed chars |
| `NoMethodError: undefined method 'base58'` | `active_support/core_ext/securerandom` not loaded | Ensure `require "custom_id"` – the gem requires it automatically |
| `NotImplementedError: CustomId::DbExtension does not support …` | `custom_id:db:*` task run against an unsupported adapter | Supported adapters: PostgreSQL, MySQL, SQLite |
| `PG::UndefinedFunction: function gen_random_bytes` | `pgcrypto` extension not enabled | Run `rails custom_id:db:enable_pgcrypto` or add `enable_extension "pgcrypto"` to a migration |
| `id = "0"` after `Model.create` on MySQL | Trigger sets string PK but `LAST_INSERT_ID()` returns `0` | Add `cid "prefix"` to the model – generates ID in Ruby before INSERT |
| Column stays `nil` after `Model.create` on MySQL (non-PK trigger) | Same root cause – AR never learns the trigger-set value | Add `cid "prefix", name: :col` to the model |
| `ArgumentError: Anonymous class is not allowed` (Rails 7.2+) | Tried to call `establish_connection` on an unnamed class | Gem internally uses `CustomId::RakeDbProxy` – no action needed; update to latest gem version if seen |
