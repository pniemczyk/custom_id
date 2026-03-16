# custom_id — Usage Patterns

## Pattern 1: Basic String Primary Key

```ruby
class User < ApplicationRecord
  cid "usr"
end

# Migration
create_table :users, id: :string do |t|
  t.string :name, null: false
  t.timestamps
end

user = User.create!(name: "Alice")
user.id  # => "usr_7xKmN2pQaBcDeFgH"
```

## Pattern 2: Custom Random Portion Size

`size:` controls the length of the random portion only.
Total ID length = `prefix.length + 1 + size`.

```ruby
class ApiKey < ApplicationRecord
  cid "key", size: 32
end

ApiKey.create!.id  # => "key_<32 Base58 chars>"
```

Use longer sizes for higher-entropy tokens (API keys, secrets).
Use shorter sizes (8–12) for human-readable reference codes.

## Pattern 3: Non-Primary-Key Column

Leave the integer or UUID primary key intact; generate the prefixed ID
into a separate string column.

```ruby
class Article < ApplicationRecord
  cid "art", name: :slug, size: 12
end

# Migration
add_column :articles, :slug, :string
add_index  :articles, :slug, unique: true

article = Article.create!(title: "Hello World")
article.id    # => 1      (integer PK)
article.slug  # => "art_aBcDeFgHiJkL"
```

Pre-setting the attribute before save skips generation:

```ruby
Article.create!(title: "Fixed slug", slug: "art_my_special_code")
# slug is NOT overwritten — the callback checks for nil
```

## Pattern 4: Embedding Parent ID Characters (`related:`)

Visually embed the first N characters of a parent model's random portion
into the child's ID for instant traceability.

```ruby
class Workspace < ApplicationRecord
  cid "wsp"
end

class Document < ApplicationRecord
  belongs_to :workspace
  cid "doc", size: 22, related: { workspace: 6 }
end
```

```ruby
ws  = Workspace.create!
ws.id   # => "wsp_ABCDEF1234567890"

doc = Document.create!(workspace: ws, title: "Spec")
doc.id  # => "doc_ABCDEF<16 random chars>"
#                  ^^^^^^ shared from workspace
```

**Constraint:** `size > chars_to_borrow` — otherwise `ArgumentError` at create time.

**Nil parent:** if the FK is nil at create time, the shared portion falls back
to `""` and the full `size` is random.

**`related:` key** must match the `belongs_to` association name exactly:

```ruby
belongs_to :user              → related: { user: 8 }          ✓
belongs_to :created_by_user   → related: { created_by_user: 8 }  ✓
belongs_to :user, foreign_key: :author_id  → related: { user: 8 }  ✓
```

## Pattern 5: Multiple `cid` Calls on One Model

Each call registers an independent `before_create` callback for a different column.

```ruby
class Contract < ApplicationRecord
  cid "ctr"                              # manages :id
  cid "ref", name: :ref_number, size: 8  # manages :ref_number
end

# Migration
create_table :contracts, id: :string do |t|
  t.string :ref_number, index: { unique: true }
  t.timestamps
end

c = Contract.create!
c.id          # => "ctr_<16 chars>"
c.ref_number  # => "ref_<8 chars>"
```

## Pattern 6: Pre-Setting IDs (Seeding / Imports)

If a value is already set when `before_create` fires, the callback skips.
Use this to import records with known IDs.

```ruby
User.create!(id: "usr_legacy_abc123", name: "Legacy User")
# id is preserved — no generation
```

## Pattern 7: Finding by ID

String IDs work with all standard AR finders:

```ruby
User.find("usr_7xKmN2pQaBcDeFgH")
User.find_by(id: "usr_7xKmN2pQaBcDeFgH")
User.where(id: ["usr_abc", "usr_def"])
```

Prefix-based scoping (not built-in — add to the model):

```ruby
scope :with_prefix, ->(prefix) { where("id LIKE ?", "#{prefix}_%") }
User.with_prefix("usr")
```

## Pattern 8: STI (Single Table Inheritance)

`cid` is registered on the class that calls it. Subclasses inherit the
`before_create` callback via normal AR callback inheritance.

```ruby
class Vehicle < ApplicationRecord
  cid "veh"
end

class Car < Vehicle; end
class Truck < Vehicle; end

Car.create!.id    # => "veh_<16 chars>"
Truck.create!.id  # => "veh_<16 chars>"
```

**Pitfall:** calling `cid` again on a subclass stacks two callbacks.
The first finds nil and generates; the second finds a non-nil value and skips.
Avoid double `cid` calls in the same hierarchy unless targeting different columns.

## Pattern 9: Manual Include (Non-Rails / Single Model)

```ruby
require "custom_id"

class MyModel < ActiveRecord::Base
  include CustomId::Concern
  cid "my"
end
```

## Pattern 10: Scopes and Queries

String IDs compose naturally with existing AR query patterns:

```ruby
class Order < ApplicationRecord
  cid "ord"

  scope :recent, -> { order(created_at: :desc) }
end

Order.find("ord_AbCdEfGhIjKlMnOp")
Order.where(user_id: user.id)  # FK is still string if user uses cid
```

## Error Reference

| Error | Cause | Fix |
|-------|-------|-----|
| `ArgumentError: size (N) must be greater than shared chars (M)` | `size <= chars_to_borrow` | Increase `size:` |
| `NOT NULL constraint failed: table.id` | `cid` not firing | Check initializer, migration schema, and model declaration |
| `NotImplementedError: does not support …` | Unsupported DB adapter for triggers | Supported: PG, MySQL, SQLite |
| `PG::UndefinedFunction: gen_random_bytes` | `pgcrypto` not enabled | `rails custom_id:db:enable_pgcrypto` |
| `id = "0"` after `create` on MySQL | String PK + trigger without `cid` on model | Add `cid` to model — see `db-triggers.md` |
