---
name: custom-id
description: 'This skill should be used when the user asks to "add custom_id", "install custom_id", "use custom_id", "add Stripe-style prefixed IDs", "generate usr_abc123 style IDs", "use a string primary key with a prefix", "add the cid macro", "embed parent ID chars into child ID", "use the related option in cid", "set up a database trigger to generate IDs", or when working with the custom_id gem in a Rails application.'
version: 1.0.0
---

# custom_id Skill

`custom_id` adds a `cid` class macro to ActiveRecord models that generates
prefixed, Base58, Stripe-style string IDs on `before_create` — no UUID, no
sequential integer leakage.

## What It Does

```ruby
# Before — integer PK, leaks row count
user = User.create!
user.id  # => 42

# After — prefixed string PK
class User < ApplicationRecord
  cid "usr"
end

user = User.create!
user.id  # => "usr_7xKmN2pQaBcDeFgH"
```

ID format: `"#{prefix}_#{random}"` where `random` is `size` Base58 characters.

Base58 alphabet omits visually ambiguous characters (`0`, `O`, `I`, `l`):
`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`

## Installation

See **`references/installation.md`** for full steps. Quick summary:

```ruby
# Gemfile
gem "custom_id"
```

```bash
bundle install
rails custom_id:install   # writes config/initializers/custom_id.rb
```

The initializer auto-includes `CustomId::Concern` into every `ActiveRecord::Base`
subclass. No manual `include` needed in individual models.

## `cid` Macro Signature

```ruby
cid(prefix, size: 16, related: {}, name: :id)
```

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `prefix` | required | String prepended before `_` (e.g. `"usr"`) |
| `size` | `16` | Length of random Base58 portion (not total ID length) |
| `name` | `:id` | Column to populate — use `:id` or any other string column |
| `related` | `{}` | Embed parent ID chars: `{ association_name => chars_to_borrow }` |

Total ID length = `prefix.length + 1 + size`

## Core Usage

### Basic — default primary key

```ruby
class User < ApplicationRecord
  cid "usr"
end

# Migration: id: :string (no default:)
create_table :users, id: :string do |t|
  t.string :name, null: false
  t.timestamps
end

user = User.create!(name: "Alice")
user.id  # => "usr_7xKmN2pQaBcDeFgH"
```

### Custom size

```ruby
class ApiKey < ApplicationRecord
  cid "key", size: 32
end
```

### Non-primary-key column

```ruby
class Article < ApplicationRecord
  cid "art", name: :slug, size: 12
end

# id stays as integer; slug gets "art_<12 chars>"
article = Article.create!(title: "Hello")
article.id    # => 1
article.slug  # => "art_aBcDeFgHiJkL"
```

Pre-setting the attribute skips generation:

```ruby
Article.create!(title: "Custom", slug: "art_my_custom_code")
# slug is NOT overwritten because it is not nil
```

### Related — embed parent ID chars

```ruby
class Workspace < ApplicationRecord
  cid "wsp"
end

class Document < ApplicationRecord
  belongs_to :workspace
  cid "doc", size: 22, related: { workspace: 6 }
end

workspace = Workspace.create!
workspace.id  # => "wsp_ABCDEF1234567890"

doc = Document.create!(workspace: workspace)
doc.id  # => "doc_ABCDEF<16 random chars>"
#                  ^^^^^^ first 6 chars of workspace's random portion
```

**Constraint:** `size` must be strictly greater than `chars_to_borrow`.
`cid "doc", size: 6, related: { workspace: 6 }` raises `ArgumentError`.

## ⚠️ Critical Rules

### Migration must use `id: :string`

```ruby
# ✅ correct — string PK, no default
create_table :users, id: :string do |t|; end

# ❌ wrong — default conflicts with gem
create_table :users, id: :string, default: nil do |t|; end
```

### `cid` after `belongs_to` when using `related:`

```ruby
# ✅ correct
class Document < ApplicationRecord
  belongs_to :workspace
  cid "doc", size: 22, related: { workspace: 6 }
end

# ❌ wrong — reflection not yet defined
class Document < ApplicationRecord
  cid "doc", size: 22, related: { workspace: 6 }
  belongs_to :workspace
end
```

### MySQL + DB triggers require `cid` on the model too

MySQL's `LAST_INSERT_ID()` returns `0` for non-`AUTO_INCREMENT` columns.
**Always** declare `cid` on the model alongside a MySQL trigger — the gem
generates the ID in Ruby before INSERT so ActiveRecord reads the correct value.

## Common Mistakes

```ruby
# ❌ double cid on the same column — only first fires
class Order < ApplicationRecord
  cid "ord"
  cid "ord"   # ← redundant, confusing
end

# ✅ one cid per column
class Order < ApplicationRecord
  cid "ord"
end

# ❌ related: key must be the association name, not the FK column
cid "doc", related: { workspace_id: 6 }   # ← wrong key

# ✅ use the belongs_to name
cid "doc", related: { workspace: 6 }
```

## Multiple `cid` Calls (Different Columns)

```ruby
class Contract < ApplicationRecord
  cid "ctr"                           # manages :id
  cid "ref", name: :ref_number, size: 8  # manages :ref_number
end
```

## Additional Resources

### Reference Files

- **`references/installation.md`** — Full setup steps, initializer content, troubleshooting
- **`references/patterns.md`** — All usage patterns with copy-paste examples
- **`references/db-triggers.md`** — Database trigger alternative for PostgreSQL, MySQL, SQLite

### Examples

- **`examples/basic.rb`** — Basic models, custom size, non-PK column
- **`examples/related.rb`** — Parent-child ID embedding with `related:`
- **`examples/db_triggers.rb`** — Migration + trigger setup per adapter
- **`examples/testing.rb`** — Minitest patterns for models using `cid`
