# CustomId – Claude Project Context

> Project-level instructions and context for Claude Code when working inside
> the `custom_id` gem repository.

## Project overview

`custom_id` is a Ruby gem that adds a `cid` class macro to ActiveRecord models
for generating prefixed, Base58, Stripe-style string IDs (e.g. `"usr_7xKmN2pQ…"`).

## Repository layout

```
lib/
  custom_id.rb               # Entry point – require this in host apps
  custom_id/
    concern.rb               # Core: cid macro via ActiveSupport::Concern
    installer.rb             # Manages config/initializers/custom_id.rb
    railtie.rb               # Rails integration, exposes rake tasks
    db_extension.rb          # Optional: PostgreSQL, MySQL, SQLite trigger-based alternative
  tasks/
    custom_id.rake           # rails custom_id:install / uninstall + custom_id:db:* tasks
test/
  test_helper.rb             # SQLite in-memory, ActiveSupport.on_load hook
  custom_id/
    concern_test.rb          # Tests for cid macro behaviour
    installer_test.rb        # Tests for Installer class
    sqlite_db_extension_test.rb  # Tests for DbExtension on SQLite
llms/
  overview.md                # Architecture overview for LLMs
  usage.md                   # Usage patterns for LLMs
AGENTS.md                    # Concise guide for AI coding agents
CLAUDE.md                    # This file
```

## Development workflow

```bash
bundle install
bundle exec rake test      # run Minitest suite (SQLite in-memory)
bundle exec rubocop        # lint
bundle exec rake           # tests + rubocop (default)
bin/console                # IRB with gem loaded
```

## Rake tasks

All `custom_id:db:*` tasks accept an optional `DATABASE` positional argument
that selects a named database from `database.yml` (multi-database apps).

| Task | Description |
|------|-------------|
| `rails custom_id:install` | Create `config/initializers/custom_id.rb` |
| `rails custom_id:uninstall` | Remove `config/initializers/custom_id.rb` |
| `rails custom_id:db:enable_pgcrypto [DATABASE]` | Enable the `pgcrypto` PG extension (required before PG triggers) |
| `rails custom_id:db:install_function [DATABASE]` | Install `custom_id_base58()` PG/MySQL function |
| `rails custom_id:db:uninstall_function [DATABASE]` | Remove the function |
| `rails "custom_id:db:add_trigger[table,prefix,column,size,DATABASE]"` | Install BEFORE INSERT trigger on a table |
| `rails "custom_id:db:remove_trigger[table,column,DATABASE]"` | Remove BEFORE INSERT trigger from a table |

The `db:*` tasks require `:environment` (full Rails boot).

## Code style

- **Double quotes** throughout (enforced by RuboCop).
- Frozen string literals on every file.
- Nested module/class syntax (`module CustomId; class Concern`) preferred over
  compact (`CustomId::Concern`).
- Test files use `module CustomId; class XxxTest < Minitest::Test` nesting.
- Metrics limits: `MethodLength: Max: 15`; test files are excluded from metrics.

## Key design decisions

1. **`cid` registers a `before_create` callback** on the calling class, not on
   `ActiveRecord::Base`. Calling `cid` twice on the same class stacks two
   callbacks – avoid this.

2. **Collision loop**: generates a Base58 ID, checks `Model.exists?(col => id)`,
   retries on collision. For `name: :id` this hits the PK index so it's fast;
   for other columns an index is recommended.

3. **`related:` option** resolves the association via `self.class.reflections`
   at callback runtime (not at `cid` declaration time) – safe for STI.

4. **`DbExtension`** is a pure class-method module; no AR callbacks involved.
   It writes SQL directly via `connection.execute`. Supports **PostgreSQL**
   (requires `pgcrypto`), **MySQL** 5.7+, and **SQLite** 3.0+.
   The `custom_id:db:*` rake tasks are thin wrappers that delegate to its class
   methods – they do no SQL themselves.

   **MySQL + ActiveRecord string PK limitation:** MySQL's `LAST_INSERT_ID()`
   returns `0` for non-`AUTO_INCREMENT` columns, so ActiveRecord cannot read
   back a trigger-generated string PK. Always pair a MySQL trigger with `cid`
   on the model. `cid` generates the ID in Ruby before INSERT (trigger fires
   only for raw SQL). This limitation does not affect PostgreSQL or SQLite.

   **Rails 7.2+ anonymous class restriction:** `establish_connection` rejects
   classes with no name. The rake tasks use `CustomId::RakeDbProxy` (a named
   abstract subclass created via `const_set`) to avoid this.

5. **Installer is decoupled from Rails**: `CustomId::Installer` takes a
   `Pathname` root and never references `Rails.root`, making it unit-testable
   with a `Dir.mktmpdir`.

6. **Multi-database support**: all `custom_id:db:*` rake tasks accept an
   optional `DATABASE` positional argument. The `resolve_connection` lambda
   uses `ActiveRecord::Base.configurations.find_db_config` to look up the
   named config and establishes a connection via `CustomId::RakeDbProxy`
   without replacing the global default connection.

## When adding features

- Add the `before_create` logic in `concern.rb` only.
- New public class-level DSL methods belong inside `class_methods do`.
- Private instance helpers used inside the callback belong in the `private`
  section of `Concern` (they are mixed into the model instance).
- Update `sig/custom_id.rbs` when adding or changing public method signatures.
- Write Minitest tests in `test/custom_id/` before implementing (TDD).
- Run `bundle exec rake` before committing – must be fully green.

## Dependency notes

- `SecureRandom.base58` comes from `active_support/core_ext/securerandom`.
- `Array#second` and `String#first(n)` come from `activesupport`.
- `Hash#present?` and `blank?` come from `activesupport`.
- All three are already pulled in by the gem's declared dependencies.

## Out of scope (do not add unless explicitly requested)

- UUID or ULID generation – use Rails' built-in `uuid` column type for that.
- Validation that the stored ID matches the expected pattern.
- Automatic index creation – migrations are the developer's responsibility.
- Support for non-ActiveRecord ORMs (Sequel, ROM, etc.).
