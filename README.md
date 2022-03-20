# Brick gem

### Have an instantly-running Rails app from only an existing database

An ActiveRecord extension that auto-creates models, views, controllers, and routes.

## Documentation

| Version        | Documentation                                             |
| -------------- | --------------------------------------------------------- |
| Unreleased     | https://github.com/lorint/brick/blob/master/README.md |
| 1.0.8          | https://github.com/lorint/brick/blob/v1.0.0/README.md |

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
the time of writing, December 2021, includes Rails 3.1 and above.  Older versions may still
function with export routines, but this is not officially supported as significant changes to
ActiveRecord came with v3.1, which means adding compatibility for any earlier versions of Rails
becomes massively troublesome.

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
ActiveRecord.  The motivation behind providing support for such old versions of ActiveRecord is
simply in the hopes that data in older applications can easily be extracted and put into newer
systems, without worrying about the details of maintaining foreign keys and such during the
transition.

Speaking of newer versions of Ruby, if you'd like to use the latest version then for those using
RVM you might have noticed that it won't yet install.  Here's the secret to install Ruby 3.0. First
make sure you're upgraded to the latest stable version of RVM:

    rvm get stable

and then download the .gz file for Ruby 3.0 from:

    https://cache.ruby-lang.org/pub/ruby/3.0/ruby-3.0.0.tar.gz

and finally move this .gz file into your .rvm/archives folder, while also renaming it in the process
to be a .tar.bz2, which can then be installed:

    mv ~/Downloads/ruby-3.0.0.tar.gz ~/.rvm/archives/ruby-3.0.0.tar.bz2
    rvm install ruby-3.0.0

### 1.b. Installation

1. Add Brick to your `Gemfile`.

    `gem 'brick'`

1. To test things, from within `rails c`, you can see that it's working by exporting some data from
   one of your models.  In this case let's have our `Product` data go out to an array.  `Product` does not yet specify anything about Brick, and seeing this, the `#df_export` routine automatically generates its own temporary template behind-the-scenes in order to define columns.  The parameter `true` being fed in says to not just show a header with column names, but also export all data as well.  To retrieve the data, the generated template is adapted to leverage ActiveRecord's `#left_joins` call to create an appropriate SQL query and retrieve all the Product data:

    ```ruby
    northwind$ bin/rails c
    Running via Spring preloader ...
    Loading development environment ...
    2.6.5 :001 > Product.df_export(true)
    Product Load (0.6ms)  SELECT "products"."product_name", categories.category_name AS category_category_name, "products"."quantity_per_unit", "products"."unit_price", "products"."units_in_stock", "products"."units_on_order", "products"."reorder_level", "products"."discontinued" FROM "products" LEFT OUTER JOIN "categories" ON "categories"."id" = "products"."category_id"
    => [["* Product Name", "* Category", "Quantity Per Unit", "Unit Price", "Units In Stock", "Units On Order", "Reorder Level", "Discontinued"], ["Camembert Pierrot", "Seafood", "100 - 100 g pieces", "43.9", "49", "0", "30", "No"], ["Pâté chinois", "Seafood", "25 - 825 g cans", "45.6", "26", "0", "0", "Yes"], ["Uncle Bob's Organic Dried Pears", "Produce", "50 bags x 30 sausgs.", "123.79", "0", "0", "0", "Yes"], ... ]
    ```

   The SQL query JOINs `products` and `categories` because the template generation logic found a `belongs_to` association going from `Product` to `Category`.  Rather than expose any numeric ID key data used between these tables, `#df_export` and `#df_import` strive to work only with non-metadata information, i.e. only human-readable columns.  The same kind of data you'd expect to find in the average spreadsheet.  To override this behaviour a template can be defined that indicates exactly the columns you'd like to use during import and export.  By default any ID columns, as well as `created_at` and `updated_at`, are omitted.

### 1.c. Generating Templates

In order for Brick to understand all the columns across any number of multiple related tables that you'd like to export and import with, a template is used.  This can be set by a constant called `IMPORT_TEMPLATE` in a model, or if that variable is missing, one is auto-generated on-the-fly.  Although the name of this variable might make it sound at first like it's only used for importing, as we have seen from above this template is also used for exporting.  Specifically the `:all` portion defines the `belongs_to` and `has_many` links to follow as various associations get traversed, and as well all the columns to reference in each table are called out.

The easiest way to generate a starter template and place it in a model is to use this Rails generator:

```bash
bin/rails g brick:model
```

As it runs, you are asked four questions:

1. Which model to use
1. If you'd like to also include models related by has_many associations.  The default is to
   only navigate across belongs_to associations, so for instance where you might want to import both Customers and Orders at the same time, then using only belongs_to associations, you would have to start from Orders, which belongs_to Customers.  And if instead you wanted to start from Customers and also include Orders, then you would need to say "Yes" to this choice of navigating across has_many associations, since Customers has_many Orders.
1. How many hops to traverse.  The system figures out the maximum number that can be navigated, and
   while using the arrow keys up and down to choose how many hops, a line is updated at the bottom of the list that shows what additional tables would be added in at each layer.
1. Final yes / no confirmation that you're OK to add this block of code to your model to set the
   IMPORT_TEMPLATE variable.

You can fully script this operation by using code such as:

```bash
bin/rails g brick:model Customer has_many 2 yes
```

Note that the four additional parameters indicate the answers to the above four questions.

Regarding the number of hops, in this case where we want to import customer and order data, if your Order model were to have a has_many association to OrderDetail then indicating as we did here to traverse two hops from Customer would first get to Order, and then also include OrderDetail, whereas choosing to go just one hop would end up only traversing from Customer to Order.  Traversing that second hop from Order could also reference a Salesperson model as well, so going a large number of hops with a more complex schema can really start to build out a pretty lengthy IMPORT_TEMPLATE -- even hundreds of lines long if you have perhaps 25 tables and choose to traverse evrything.

To do this creation of a template more programmatically, you can use the #suggest_template method on a model.  In fact, for models that do not yet specify an IMPORT_TEMPLATE, the system does exactly this to auto-generate a default template, such as this one that would be created on-the-fly for a Product model:

```ruby
3.0.0 :002 > Product.suggest_template

# Place the following into app/models/product.rb:
# Generated by:  Product.suggest_template(0, false, true)
IMPORT_TEMPLATE = {
  uniques: [:product_name],
  required: [],
  all: [:product_name, :quantity_per_unit, :unit_price, :units_in_stock, :units_on_order, :reorder_level, :discontinued,
    { category: [:category_name] }],
  as: {}
}.freeze
# ------------------------------------------

 => {:uniques=>[:product_name], :required=>[], :all=>[:product_name, ...
3.0.0 :002 >
```

Digging into more of the specifics of all the parts of this IMPORT_TEMPLATE, notice that in a couple different places column names can be included, describing to `#df_export` and `#df_import` which columns to utilise.  The `:uniques` and `:required` are lists of columns that are used during import to identify unique new rows vs existing rows, in order to choose on a row-by-row basis between doing an INSERT vs an UPDATE.  With `:uniques` defined, INSERT vs UPDATE is automatically determined by seeing if any existing row matches against the incoming rows for those specific columns.  If you always want to add new rows then leave :uniques empty, and then doing the same import three times would generate triple the data, leaving you to sort out the duplicates perhaps with ActiveRecord's own :id and :created_at columns.  So generally it's a good idea to populate the :uniques entry with appropriate values to minimise the risk of duplicate data coming in.  In the case of importing users, perhaps a unique you might use would be a person's email address since other things, like their phone number or even their last name, might sometimes change.  Then when re-importing over existing data, an existing user can get updated as long as their email address hasn't changed.

Seeing this simple starting template for `Product` is useful, but perhaps you'd like a more thorough template to work with.  After all, ActiveRecord is a very powerful ORM when used with relational data sets, so as long as you've got appropriate `belongs_to` and `has_many` associations established then `#suggest_template` can use these to work across multiple related tables.  Effectively the schema in your application becomes a graph of nodes which gets traversed.  Let's see how easy it is to create a more rounded out template, this time examining a template for the `Order` model.  Not specifying any extra "hops" brings back a template with this `:all` portion:

```ruby
all: [:order_date, :required_date, :shipped_date, :ship_via_id, :freight, :ship_name, :ship_address, :ship_city, :ship_region, :ship_postal_code, :ship_country, :customer_code,
    { customer: [:company_code] },
    { employee: [:first_name] }]
```

You might want to include more tables, or have the existing ones be more "rounded out" with all their columns.  for these kinds of tricks the `#suggest_template` method accepts two incoming parameters, the number of hops to traverse to related tables, and a boolean for if you would like to also navigate across `has_many` associations in addition to the `belongs_to` associations (which are always traversed).  These are the same options available from the command line when using the Rails generator.  In the last example, even without specifying a number of hops the related tables `customer` and `employee` were referenced, but each with just one column listed as the system did a best-effort approach to find the most human-readable unique-ish column to utilise for doing a lookup.  This is what happens when you choose to traverse 0 hops in the generator.  Columns from these other related tables still appeared because the `Order` model has belongs_to associations, and thus foreign keys for, these two associated tables.  The template generation logic examined these two destination tables, and not knowing initially what non-metadata column might be considered unique, had just chosen the first string columns available in these, which were `company_code` and `first_name`.  Thankfully these end up being good choices for our data.

To go further, we can now specify one additional hop to traverse from that starting table, as well as indicate that we'd like to go across the `has_many` associations as well, by doing:

```ruby
Order.suggest_template(1, true)
```

which returns this `:all` entry:

```ruby
all: [:order_date, :required_date, :shipped_date, :ship_via_id, :freight, :ship_name, :ship_address, :ship_city, :ship_region, :ship_postal_code, :ship_country, :customer_code,
    { customer: [:company_code, :company_name, :contact_name, :contact_title, :address, :city, :region, :postal_code, :country, :phone, :fax] },
    { employee: [:first_name, :last_name, :title, :title_of_courtesy, :birth_date, :hire_date, :address, :city, :region, :postal_code, :country, :home_phone, :extension, :notes,
      { reports_to: [:first_name] }] },
    { order_details: [:unit_price, :quantity, :discount,
      { product: [:product_name] }] }]
```

We see here that the entries for `customer` and `employee` are much more rounded out, having all their column detail included.  Plus it further includes listings for any belongs_to associations these tables have, such as `reports_to` for `employee`.  This is effectively already two hops away even though we had only specified one, so what gives?  Well, it would be impossible to represent an entry for the reports_to_id unless you were using numerical IDs, so in lieu of this Brick goes the distance and finds some kind of human-readable option to let you associate an Employee to their boss (through the reports_to association).

Because :customer and :employee have all columns shown, this allows all their data to be exported or imported along with the `Order` data.  Doing an export will do the JOINs and grab all these columns in what would be termed a "denormalised" set of data, much like many people's busy spreadsheets resemble.  If you put this into Excel and remove a few columns, such as omitting :region, :fax, and :home_phone, then the import is fine with this and simply puts NULL values in the database for whatever columns are omitted.  As well, if you'd like to rearrange the order of the columns then it works fine.  Because the first row contains the column header data, the system is able to identify which columns relate to which data.

The `:order_details` entry is there simply because we specified to also include `has_many`, this by calling the method with the second argument as `true`.  Generally it's best to only traverse `belongs_to` associations, which by default is all that `#suggest_template` tries to do.  But in this case it would be impossible to populate `order_details` (without using ID fields and numerical metadata anyway) unless we had possibility to use this kind of `has_many` linkage.  So including `has_many` associations here makes total sense.

### 1.d. Exporting Data

(Coming soon)

### 1.e. Using rails g df_export

(Coming soon)

### 1.f. Importing Data

(Coming soon)

## 2. More Fancy Exports

### 2.a. Simplify Column Names Using Aliases

(Coming soon)

### 2.b. Filtering the Rows to Export

(Coming soon)

### 2.c. Seeing the Resulting JOIN Strategy and SQL Used

(Coming soon)

## 3. More Fancy Imports

### 3.a. Self-referencing models

(Coming soon)

### 3.b. Polymorphic Inheritance

(Coming soon)

### 3.c. Single Table Inheritance (STI)

(Coming soon)

### 3.d. Tweaking For Performance

(Coming soon)

### 3.e. Using Callbacks

(Coming soon)

## Problems

Please use GitHub's [issue tracker](https://github.com/lorint/brick/issues).

## Contributing

In order to run the examples, first make sure you have Ruby 2.7.5 installed, and then:

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

[1]: https://github.com/lorint/brick/tree/1-stable
[3]: http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#module-ActiveRecord::Associations::ClassMethods-label-Polymorphic+Associations
[4]: http://api.rubyonrails.org/classes/ActiveRecord/Base.html#class-ActiveRecord::Base-label-Single+table+inheritance
[5]: https://github.com/lorint/brick/blob/master/doc/CONTRIBUTING.md
