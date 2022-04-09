# Brick gem

### Have an instantly-running Rails app from only an existing database

An ActiveRecord extension that auto-creates models, views, controllers, and routes.

## Documentation

| Version        | Documentation                                             |
| -------------- | --------------------------------------------------------- |
| Unreleased     | https://github.com/lorint/brick/blob/master/README.md |
| 1.0.19         | https://github.com/lorint/brick/blob/v1.0.0/README.md |

## Table of Contents

<!-- toc -->

- [1. Getting Started](#1-getting-started)
  - [1.a. Compatibility](#1a-compatibility)
  - [1.b. Installation](#1b-installation)
  - [1.c. Generating Templates](#1c-generating-templates)
  - [1.d. Exporting Data](#1d-exporting-data)
  - [1.e. Using rails g df_export](#1e-using-rails-g-df-export)
  - [1.f. Importing Data](#1e-importing-data)
- [2. More Fancy Exports](#2-limiting-what-is-versioned-and-when)
  - [2.a. Simplify Column Names Using Aliases](#2a-simplify-column-names-using-aliases)
  - [2.b. Filtering the Rows to Export](#2b-filtering-the-rows-to-export)
  - [2.c. Seeing the Resulting JOIN Strategy and SQL Used](#2c-seeing-the-resulting-join-strategy-and-sql-used)
- [3. More Fancy Imports](#3-more-fancy-imports)
  - [3.a. Self-referencing models](#3a-self-referencing-models)
  - [3.b. Polymorphic Inheritance](#3b-polymorphic-inheritance)
  - [3.c. Single Table Inheritance (STI)](#3c-single-table-inheritance-sti)
  - [3.d. Tweaking For Performance](#3d-tweaking-for-performance)
  - [3.e. Using Callbacks](#3e-using-callbacks)
- [4. Similar Gems](#10-similar-gems)
- [Problems](#problems)
- [Contributing](#contributing)
- [Intellectual Property](#intellectual-property)

<!-- tocstop -->

## 1. Getting Started

### 1.a. Compatibility

| brick      | branch     | tags   | ruby     | activerecord  |
| -------------- | ---------- | ------ | -------- | ------------- |
| unreleased     | master     |        | >= 2.3.5 | >= 3.0, < 7.1 |
| 1.0            | 1-stable   | v1.x   | >= 2.3.5 | >= 3.0, < 7.1 |

Brick supports all Rails versions which have been current during the past 10 years, which at
the time of writing, May 2022, includes Rails 3.1 and above.  Older versions may still
function, but this is not officially supported as significant changes to ActiveRecord came
with v3.1, and being as this gem is fairly tightly integrated with everything at the data
layer, adding compatibility for earlier versions of Rails becomes difficult.

Brick has a compatibility layer which is automatically applied when used along with older
versions of Rails.  This is provided in order to more easily test the broad range of supported
versions of ActiveRecord.  When running Rails older than v4.2 on Ruby v2.4 or newer then
normally everything fails because Fixnum and Bignum were merged to become Integer with newer
versions of Ruby.  This gem provides a patch for this scenario, as well as patches for places
Ruby 2.7 would normally error out due to circular references in method definitions in TimeZone
and HasManyAssociation.

When using the Brick gem with Rails 3.x, more patches are applied to those antique versions
of ActiveRecord in order to add #find_by, #find_or_create_by, and an updated version of #pluck.
This fills in the gaps to allow the gem to work along with the limitations of early versions of
ActiveRecord.

### 1.b. Installation

1. Add Brick to your `Gemfile`.

    `gem 'brick'`

1. To test things, configure database.yml to use Postgres, Sqlite3, or MySQL, and to point to a relational database.  Then from within `rails c` attempt to reference a model by what its normal name might be.  For instance, if you have a `plants` table then just type `Plant.count` and see that automatically a model is built out on-the-fly and the count for this `plants` table is shown.  If you similarly have `products` that relates to `categories` with a foreign key then notice that by referencing `Category` the gem builds out a model which has a has_many association called :products.  Without writing any code these associations are all wired up as long as you have proper foreign keys in place.

To configure myriad options, such as defining related columns that you want to have act as if they were a foreign key, then you can build out an initializer file for Brick.  The gem automatically provides some suggestions for you based on your current database, so it's useful to make sure your database.yml file is properly configured before continuing.  By using the `install` generator, the file `config/initializers/brick.rb` is automatically written out and here is the command:

    ```
    bin/rails g brick:install
    ```

Inside the generated file many options exist, and one of which is `Brick.additional_references` which defines additional foreign key associations, and even shows some suggested ones where possible.  By default these are commented out, and by un-commenting the ones you would like (or perhaps even all of them), then it is as if these foreign keys were present to provide referential integrity.  If you then start up a `rails c` you'll find that appropriate belongs_to and has_many associations are automatically fleshed out.  Even has_many :through associations are provided when possible associative tables are identified -- that is, tables having only foreign keys that refer to other tables.

## Problems

Please use GitHub's [issue tracker](https://github.com/lorint/brick/issues).

## Contributing

In order to run the examples, first make sure you have Ruby 2.7.x installed, and then:

```
gem install bundler:1.17.3
bundle
bundle exec appraisal ar-6.1 bundle
DB=sqlite bundle exec appraisal

```

See our [contribution guidelines][5]

## Setting up my MySQL

If you're on Ruby 2.7 or later:
    sudo apt-get install default-libmysqlclient-dev

On OSX / MacOS with Homebrew:
    brew install mysql 
    brew services start mysql

On an Apple Silicon machine (M1 / M2 / M3 processor) then also set this:
    bundle config --local build.mysql2 "--with-ldflags=-L$(brew --prefix zstd)/lib"

(and maybe even this if the above doesn't work out)
    bundle config --local build.mysql2 "--with-opt-dir=$(brew --prefix openssl)" "--with-ldflags=-L$(brew --prefix zstd)/lib"


And once the service is up and running you can connect through socket /tmp/mysql.sock like this:
    mysql -uroot

And inside this console now create two users with various permissions (these databases do not need to yet exist).  Trade out "my_username" with your real username, such as "sally@localhost".

    CREATE USER my_username@localhost IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON duty_free_test.* TO my_username@localhost;
    GRANT ALL PRIVILEGES ON duty_free_foo.* TO my_username@localhost;
    GRANT ALL PRIVILEGES ON duty_free_bar.* TO my_username@localhost;

    And then create the user "duty_free" who can only connect locally:
    CREATE USER duty_free@localhost IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON duty_free_test.* TO duty_free@localhost;
    GRANT ALL PRIVILEGES ON duty_free_foo.* TO duty_free@localhost;
    GRANT ALL PRIVILEGES ON duty_free_bar.* TO duty_free@localhost;
    EXIT

Now you should be able to set up the test database for MySQL with:

    DB=mysql bundle exec rake prepare

And run the tests on MySQL with:

    bundle exec appraisal ar-7.0 rspec spec

## Intellectual Property

Copyright (c) 2020 Lorin Thwaits (lorint@gmail.com)
Released under the MIT licence.

[5]: https://github.com/lorint/brick/blob/master/doc/CONTRIBUTING.md
