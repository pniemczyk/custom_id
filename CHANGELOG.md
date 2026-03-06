# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-02-27

### Added

- `CustomId::Concern` with the `cid` class macro for generating prefixed Base58 string IDs
- Support for embedding shared characters from a related model's ID (`related:` option)
- Support for targeting a non-primary-key column (`name:` option)
- Configurable random-portion length (`size:` option)
- `CustomId::Installer` for creating/removing the Rails initializer
- `CustomId::Railtie` with `custom_id:install` and `custom_id:uninstall` rake tasks
- `CustomId::DbExtension` – optional PostgreSQL trigger-based ID generation
