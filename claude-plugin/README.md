# custom_id — Claude Code Plugin

A Claude Code plugin that teaches Claude how to install and use the
[`custom_id`](https://github.com/pniemczyk/custom_id) gem in any Rails application.

## What's Included

```
claude-plugin/
├── .claude-plugin/
│   └── plugin.json                          # Plugin metadata
└── skills/
    └── custom-id/
        ├── SKILL.md                         # Core skill — auto-loaded when relevant
        ├── references/
        │   ├── installation.md              # Step-by-step setup guide
        │   ├── patterns.md                  # Usage patterns and recipes
        │   └── db-triggers.md               # Database trigger alternative guide
        └── examples/
            ├── basic.rb                     # Basic model examples
            ├── related.rb                   # Related model (shared-chars) examples
            ├── db_triggers.rb               # DB trigger setup examples
            └── testing.rb                   # Minitest test patterns
```

## Installing the Plugin

### Option A — Point Claude Code at the plugin directory

```bash
# One-off session
claude --plugin-dir /path/to/custom_id/claude-plugin

# Or copy the plugin directory to your project
cp -r /path/to/custom_id/claude-plugin /your/project/.claude-plugins/custom-id
```

### Option B — Install globally in `~/.claude`

```bash
mkdir -p ~/.claude/plugins/custom-id
cp -r /path/to/custom_id/claude-plugin/* ~/.claude/plugins/custom-id/
```

## How the Skill Activates

The skill automatically activates when you ask Claude things like:

- "Add custom_id to this project"
- "Install custom_id"
- "Add Stripe-style prefixed IDs to my model"
- "Generate `usr_abc123` style IDs for User"
- "Use a string primary key with a prefix"
- "Embed parent ID chars into child ID"
- "Add a `cid` macro to my model"
- "Set up a database trigger to generate IDs"

Claude will then know:
1. How to add the gem and run the installer
2. How to call `cid` with all options: `prefix`, `size`, `name:`, `related:`
3. The migration requirements (`:string` primary key, no `default:`)
4. The `related:` parent-embedding pattern and its constraints
5. The database trigger alternative for PostgreSQL, MySQL, and SQLite
6. MySQL-specific gotchas with string PKs
7. How to write Minitest tests for models using `cid`
