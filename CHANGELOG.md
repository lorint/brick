# Changelog

This project follows [Semantic Versioning (SemVer) 2.0.0](http://semver.org/spec/v2.0.0.html) and the
recommendations of [keepachangelog.com](http://keepachangelog.com/).

## Unreleased

### Breaking Changes

- None

### Added

- None

### Fixed

- None

## 1.0.10 (2022-03-22)

View template for show

### Breaking Changes

- None

### Added

- Auto-establish show actions in the controller, and show view templates that use a simple DSL to look up foreign columns

### Fixed

## 1.0.8 (2022-03-20)

Support for HMT associations

### Breaking Changes

- None

### Added

- Auto-establish HMT associations for tables which have multiple foreign keys to the same destination

### Fixed

- None
## 1.0.6 (2022-03-19)

Auto-detect single table inheritance

### Breaking Changes

- None

### Added

- Support to auto-establish STI based on configuration options

### Fixed

- None
## 1.0.5 (2022-03-19)

Support for has_one

### Breaking Changes

- None

### Added

- Support for has_one via the has_ones configuration option

### Fixed

- None
## 1.0.4 (2022-03-16)

Support for MySQL and Sqlite3

### Breaking Changes

- None

### Added

- Support for MySQL and Sqlite3

### Fixed

- None

## 1.0.3 (2022-03-14)

Support for has_many :through

### Breaking Changes

- None

### Added

- Support for has_many :through

### Fixed

- None

## 1.0.2 (2022-03-13)

Addition of controllers, views, and routes to show index views

### Breaking Changes

- None

### Added

- Auto-creation of controllers with a simple index action
- Auto-creation of index views which show a list of rows

### Fixed

- None

## 1.0.0 (2022-03-10)

First major release of the Brick gem, auto-creating models from an existing set of database tables.

### Breaking Changes

- None

### Added

- First release of gem with basic core functionality

### Fixed

- None
