# custom_id — Installation Guide

## Requirements

- Ruby ≥ 3.0
- Rails 7.x or 8.x (ActiveRecord + ActiveSupport + Railties ≥ 7.0)

## Step 1: Add to Gemfile

```ruby
# Gemfile
gem "custom_id"
```

```bash
bundle install
```

## Step 2: Generate the Initializer

```bash
rails custom_id:install
```

This writes `config/initializers/custom_id.rb`:

```ruby
# frozen_string_literal: true

ActiveSupport.on_load(:active_record) do
  include CustomId::Concern
end
```

The `on_load` callback fires once when ActiveRecord is fully loaded.
Every `ApplicationRecord` subclass automatically has the `cid` macro —
no manual `include` in individual models.

**The task is idempotent:** running it again when the file already exists
prints a skip message and leaves the file unchanged.

## Step 3: Prepare the Migration

For tables where `cid` manages the **primary key**, declare the id column
as `:string` with **no `default:`**:

```ruby
class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users, id: :string do |t|
      t.string :name,  null: false
      t.string :email, null: false, index: { unique: true }
      t.timestamps
    end
  end
end
```

For a **non-PK column**, add a regular string column (with an index if you
query by it):

```ruby
class AddSlugToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :slug, :string
    add_index  :articles, :slug, unique: true
  end
end
```

## Step 4: Add `cid` to the Model

```ruby
class User < ApplicationRecord
  cid "usr"
end

class Article < ApplicationRecord
  cid "art", name: :slug, size: 12
end
```

## Uninstalling

```bash
rails custom_id:uninstall
```

Removes `config/initializers/custom_id.rb`. Idempotent — safe to run
when the file is already absent.

## Manual Include (Without the Rails Initializer)

For non-Rails setups or for a single model only:

```ruby
require "custom_id"

class MyModel < ActiveRecord::Base
  include CustomId::Concern
  cid "my"
end
```

Or in `ApplicationRecord` itself:

```ruby
class ApplicationRecord < ActiveRecord::Base
  include CustomId::Concern
  primary_abstract_class
end
```

## Verifying the Installation

Open a Rails console and check:

```ruby
# Concern available
CustomId::Concern   # should not raise NameError

# Auto-included into every AR model
ActiveRecord::Base.ancestors.include?(CustomId::Concern)   # => true

# Quick smoke test (assumes a users table with id: :string)
User.create!(name: "Test").id   # => "usr_<16 chars>"
```

## Troubleshooting

**`NOT NULL constraint failed: table.id`**
→ The `cid` callback is not firing. Check: (1) the initializer exists,
(2) the model has `cid "prefix"`, (3) the migration uses `id: :string`.

**`id = "0"` after `Model.create` on MySQL**
→ MySQL's `LAST_INSERT_ID()` returns `0` for non-`AUTO_INCREMENT` columns
when combined with a DB trigger. Fix: declare `cid` on the model alongside
the trigger. See `db-triggers.md`.

**`ArgumentError: size (N) must be greater than the number of shared characters (M)`**
→ Increase `size:` or reduce the borrowed character count in `related:`.

**`NotImplementedError: CustomId::DbExtension does not support …`**
→ The `custom_id:db:*` rake tasks only support PostgreSQL, MySQL, and SQLite.

**`PG::UndefinedFunction: function gen_random_bytes`**
→ The `pgcrypto` extension is not enabled. Run:
`rails custom_id:db:enable_pgcrypto`
or add `enable_extension "pgcrypto"` to a migration.
