# Brick gem

### Have an instantly-running Rails app from any existing database

Welcome to a seemingly-magical world of spinning up simple and yet well-rounded applications
from any existing relational database!  This gem auto-creates models, views, controllers, and
routes.

## Documentation

| Version        | Documentation                                             |
| -------------- | --------------------------------------------------------- |
| Unreleased     | https://github.com/lorint/brick/blob/master/README.md |
| 1.0.22         | https://github.com/lorint/brick/blob/v1.0.0/README.md |

You can use The Brick in several ways -- from taking a quick peek inside an existing data set,
with full ability to navigate across associations, to easily updating and creating data,
exporting tables or views out to CSV or Google Sheets, importing sets of data, creating a
minimally-scaffolded application one file at a time, experimenting with various data layouts to
see how functional a given database design will be, and more.

One core goal behind The Brick is to adhere as closely as possible to Rails conventions.  As
such, models, controllers, and views are treated independently.  You can use this tool to only
build out models if you wish, and then make your own controllers and views.  Or have The Brick
make generic controllers and views for some resources as you fine-tune others with custom code.
Or you could go the other way around -- you build the models, and have The Brick auto-create
the controllers and views.  Any kind of hybrid approach is possible.  The idea is to use
The Brick to automatically provide the more tedious and simple parts of your application,
allowing you to focus effort on the tricky custom parts.

In terms of models, all major ActiveRecord associations can be used, including has_many and
belongs_to, as well as has_many :through, Single Table Inheritance (STI), and polymorphic
associations.  Appropriate belongs_tos are built based on the foreign keys already in the
database, and corresponding has_many associations are also built as inverses of the discovered
belongs_tos.  From there for any tables which only have belongs_to fields, relevant
has_many :through associations are added.  For example, if there are recipes and ingredients
set up with an associative table like this:

    Recipe --> RecipeIngredient <-- Ingredient

then first there are two belongs_to associations placed in RecipeIngredient, and then two
corresponding inverse associations -- has_manys -- one in Recipe, and one in Ingredient.
Finally with RecipeIngredient being recognised as an associative table (as long as it has no
other columns than those two foreign keys, recipe_id and ingredient_id, then in Recipe a HMT
would be added:

    `has_many :ingredients, through: :recipe_ingredients`

and in Ingredient another HMT would be added:

    `has_many :recipes, through: :recipe_ingredients`

So when you run the whole thing you could navigate to https://localhost:3000/recipes, and see
each recipe and also all the ingredients which it requires through its HMT.

If either (or both) of the foreign keys were missing in the database, they could be added as an
additional_reference.  Say that the foreign key between Recipe and RecipeIngredient is missing.
It can be provided by putting a line like this in an initialiser file:

    `::Brick.additional_references = [['recipe_ingredients', 'recipe_id', 'recipes']]`

Brick can auto-create such an initialiser file, and often infer these kinds of useful references
to fill in the gaps for missing foreign keys.  These suggestions are left commented out initially,
so very easily brought into play by editing that file.  Myriad settings are avaiable therein.

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
with v3.1, and being as much of this gem is tightly integrated with everything at the data
layer, adding compatibility for earlier versions of Rails is difficult.

If you are using Rails 4.x or older, then you MUST have this to be the last line in boot.rb:

    require 'brick/compatibility'

In Rails >= 7.x the Zeitwerk loader is fully functional, no compatibility issues.  (And this
version of Rails is the one that has been tested the most.)

Rails 6.0.x uses an interim version of Zeitwerk that is not yet compatible with The Brick,
so at this point you must use classic mode by putting this line in application.rb:

    config.autoloader = :classic

When used with various older versions of Rails, Brick has a compatibility layer which is
automatically applied.  This makes it easier to test the broad range of supported versions
of ActiveRecord.  An example compatibility provided is when running any Rails older than v4.2
on Ruby v2.4 or newer then normally everything fails because starting with Ruby 2.4 Fixnum and
Bignum were merged to become Integer.  This gem provides a patch for this scenario, as well as
patches for places Ruby 2.7 and newer would normally error out due to circular references in
method definitions in TimeZone and HasManyAssociation.

When using the Brick gem with Rails 3.x, more patches are applied to those antique versions of
ActiveRecord in order to add #find_by, #find_or_create_by, and an updated version of #pluck.

### 1.b. Installation

1. Add Brick to your `Gemfile`.

    `gem 'brick'`

1. To test things, configure database.yml to use Postgres, Sqlite3, or MySQL, and to point to a relational database.  Then from within `rails c` attempt to reference a model by what its normal name might be.  For instance, if you have a `plants` table then just type `Plant.count` and see that automatically a model is built out on-the-fly and the count for this `plants` table is shown.  If you similarly have `products` that relates to `categories` with a foreign key then notice that by referencing `Category` the gem builds out a model which has a has_many association called :products.  Without writing any code these associations are all wired up as long as you have proper foreign keys in place.

To configure myriad options, such as defining related columns that you want to have act as if they were a foreign key, then you can build out an initializer file for Brick.  The gem automatically provides some suggestions for you based on your current database, so it's useful to make sure your database.yml file is properly configured before continuing.  By using the `install` generator, the file `config/initializers/brick.rb` is automatically written out and here is the command:

    `bin/rails g brick:install`

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
