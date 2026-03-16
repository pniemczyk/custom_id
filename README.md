# CustomId

Generate unique, human-readable, prefixed string IDs for ActiveRecord models – inspired by Stripe-style identifiers like `usr_7xKmN2pQ…`.

## Features

* One-line `cid` macro – declare a prefix and the gem handles the rest
* Collision-resistant loop with database uniqueness check
* Embed shared characters from a parent model's ID for visual traceability
* Target any string column, not just `id`. Ensure you set the column as a string primary key if using `id`.
* Configurable random-portion length
* Rails installer (`rails custom_id:install`) that auto-includes the concern
* Optional **database trigger-based** alternative for DB-level enforcement (PostgreSQL, MySQL, SQLite)

## Installation

Add to your application's `Gemfile`:

```ruby
gem "custom_id"
```

Then run:

```bash
bundle install
rails custom_id:install
```

The installer creates `config/initializers/custom_id.rb` which auto-includes `CustomId::Concern` into every ActiveRecord model via `ActiveSupport.on_load(:active_record)`.

## Usage

### Basic usage

```ruby
class User < ApplicationRecord
  cid "usr"
end

User.create!(name: "Alice").id  # => "usr_7xKmN2pQaBcDeFgH"
```

The ID format is `<prefix>_<random>` where the random part is 16 Base58 characters by default.
.cid by default use the `id` column as the target for generated IDs, so make sure to set it as a string primary key in your migration. Like this: `bin/rails g model Account id:string:primary_key`

### Custom size

```ruby
class ApiKey < ApplicationRecord
  cid "key", size: 32
end

ApiKey.create!.id  # => "key_Ab3xY7mN…" (32 random chars)
```

### Embed shared characters from a related model

Pass `related: { association_name => chars_to_borrow }` to prefix the random portion with characters borrowed from the related model's ID. This creates visual traceability between parent and child IDs.

```ruby
class Document < ApplicationRecord
  belongs_to :workspace
  cid "doc", size: 24, related: { workspace: 6 }
end

# workspace.id => "wsp_ABCDEF…"
# document.id  => "doc_ABCDEF<18 random chars>"
```

### Custom column

Use `name:` to generate the ID into a non-primary-key column:

```ruby
class Article < ApplicationRecord
  cid "art", name: :slug, size: 12
end

Article.create!(title: "Hello").slug  # => "art_aBcDeFgHiJkL"
```

The primary key is left untouched; set it as usual.

### Manual include (without the Rails initializer)

```ruby
class MyModel
  include CustomId::Concern
  cid "my"
end
```

## Database-side alternative (PostgreSQL, MySQL, SQLite)

For applications that need IDs generated even when records are inserted via raw SQL (e.g., bulk imports, database-level ETL), `CustomId::DbExtension` installs database triggers that produce the same prefixed Base58 IDs.

### Requirements

* **PostgreSQL**: 9.6+ (requires `pgcrypto` extension)
* **MySQL**: 5.7+ (uses `RANDOM_BYTES`)
* **SQLite**: 3.0+ (uses `AFTER INSERT` trigger)

### MySQL + ActiveRecord: always pair with `cid`

MySQL's protocol does not expose a generated string PK back to the caller after INSERT (unlike PostgreSQL's `RETURNING`). When ActiveRecord inserts a row without an `id` value it reads `LAST_INSERT_ID()`, which returns `0` for non-`AUTO_INCREMENT` columns — so the in-memory record gets `id = "0"` even though the row in the database has the correct trigger-generated value.

**Solution:** declare `cid` on the model alongside the trigger. `cid` generates the ID in Ruby *before* the INSERT, so Rails includes it in the column list and `LAST_INSERT_ID()` is never consulted. The trigger's `WHEN NEW.id IS NULL` guard makes it a no-op for AR inserts and a safety net for raw-SQL inserts.

```ruby
# model
class Order < ApplicationRecord
  cid "ord"   # generates id in Ruby; trigger fires only for raw SQL inserts
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

This limitation does **not** affect PostgreSQL or SQLite.

### Migration example (PostgreSQL)

```ruby
class CreateUsers < ActiveRecord::Migration[7.0]
  def up
    enable_extension "pgcrypto"   # only needed once per database

    create_table :users, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end

    CustomId::DbExtension.install_trigger!(connection, :users, prefix: "usr")
  end

  def down
    CustomId::DbExtension.uninstall_trigger!(connection, :users)
    drop_table :users
  end
end
```

### Trade-offs

| Aspect                     | Ruby concern (`cid`)  | `DbExtension` trigger          |
|----------------------------|-----------------------|--------------------------------|
| Portability                | Any AR adapter        | PG, MySQL, SQLite only         |
| Bulk / raw inserts         | IDs **not** generated | IDs **always** generated       |
| Testability                | SQLite in-memory ok   | Needs a real DB connection     |
| Related-model IDs          | Supported             | Not supported                  |
| Migration needed           | No                    | Yes                            |
| MySQL + AR id read-back    | ✅ Works              | ⚠️ Needs `cid` on model too    |

## Rails installer tasks

```bash
rails custom_id:install    # create config/initializers/custom_id.rb
rails custom_id:uninstall  # remove  config/initializers/custom_id.rb
```

## Database-side rake tasks

The `custom_id:db:*` tasks manage `CustomId::DbExtension` objects from the command line without writing migration code. All tasks depend on the Rails `:environment` task.

An optional `DATABASE` argument targets a specific database in a multi-database Rails app (matches the name from `database.yml`). Omit it to use the default connection.

```bash
# Enable the pgcrypto extension (PostgreSQL only – required before install_function / add_trigger)
rails custom_id:db:enable_pgcrypto
rails "custom_id:db:enable_pgcrypto[postgres]"       # multi-database

# optional add migration

```
class EnablePgcrypto < ActiveRecord::Migration[8.1]
  def up   = enable_extension "pgcrypto"
  def down = disable_extension "pgcrypto"
end
```

# Install the shared Base58 generator function (once per database)
rails custom_id:db:install_function
rails "custom_id:db:install_function[postgres]"       # multi-database

# Remove the shared function
rails custom_id:db:uninstall_function
rails "custom_id:db:uninstall_function[postgres]"     # multi-database

# Add a BEFORE INSERT trigger to a table (column defaults to id, size defaults to 16)
rails "custom_id:db:add_trigger[users,usr]"
rails "custom_id:db:add_trigger[reports,rpt,report_key,24]"
rails "custom_id:db:add_trigger[users,usr,,,postgres]"        # multi-database, default column/size
rails "custom_id:db:add_trigger[reports,rpt,report_key,24,postgres]"  # all options

# Remove a BEFORE INSERT trigger from a table
rails "custom_id:db:remove_trigger[users]"
rails "custom_id:db:remove_trigger[reports,report_key]"
rails "custom_id:db:remove_trigger[users,,postgres]"          # multi-database
```

`install_trigger!` is idempotent – it is safe to call again if the trigger already exists.

> **PostgreSQL setup order:** `enable_pgcrypto` → `install_function` is handled automatically by `add_trigger`, but if you run them separately keep that order. If pgcrypto is missing you will see:
> ```
> error: The pgcrypto PostgreSQL extension is required but not enabled.
>        Run: rails custom_id:db:enable_pgcrypto
>        or add enable_extension "pgcrypto" to a migration.
> ```

## Claude Code Skill

A Claude Code skill is bundled at `claude-plugin/custom-id.skill`. It teaches
Claude how to install and use this gem inside any Rails project.

### What the skill covers

- `cid` macro signature and all options (`prefix`, `size`, `name:`, `related:`)
- Migration requirements (`id: :string`, no `default:`)
- Parent-embedded IDs with `related:`
- Database trigger alternative for PostgreSQL, MySQL, and SQLite
- MySQL string PK gotcha and the required `cid` + trigger pairing
- Minitest patterns for models that use `cid`

### Installing the skill

```bash
# Option A — project-level plugin
cp -r claude-plugin /your/project/.claude-plugins/custom-id

# Option B — global install
mkdir -p ~/.claude/plugins/custom-id
cp -r claude-plugin/* ~/.claude/plugins/custom-id/
```

Once installed, Claude activates the skill automatically when you ask things
like *"add custom_id to this project"*, *"generate Stripe-style prefixed IDs"*,
or *"add the `cid` macro to my model"*.

## Development

```bash
bin/setup         # install dependencies
bundle exec rake  # run tests + RuboCop
bin/console       # interactive prompt
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/pniemczyk/custom_id.

## License

MIT – see [LICENSE.txt](LICENSE.txt).
