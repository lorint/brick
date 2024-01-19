# Build it faster with The Brick!

### Have an instantly-running Rails app from any existing database

Welcome to a seemingly-magical world of spinning up simple and yet well-rounded applications
from any existing relational database!  This gem auto-creates models, views, controllers, and
routes, and instead of being some big pile of raw scaffolded files, they exist just in RAM.
The beauty of this is that if you make database changes such as adding new tables or columns,
basic functionality is immediately available without having to add any code.  General behaviour
around things like having lists be read-only, or when editing is enabled then rules about
how to render the layout -- either inline or via a pop-up modal -- can be established.  More
refined behaviour and overrides for the defaults can be applied on a model-by-model basis.

| ![sample look at sales data](./docs/erd3.png) |
|-|

You can use The Brick in several ways -- from taking a quick peek inside an existing data set,
with full ability to navigate across associations -- to easily updating and creating data,
exporting tables or views out to CSV or Google Sheets -- to importing sets of data, even when
each row targets multiple destination tables -- to auto-creating API endpoints -- to creating a minimally-scaffolded application
one file at a time -- to experimenting with various data layouts, seeing how functional a given
database design will be -- and more.

A good general overview of how to start from scratch can be seen in **[this Youtube video by Deanin](https://www.youtube.com/watch?v=Vq6oGO727Qg)**.
Big thanks out to you, man!

Also available is this older video walkthrough that I had done.  Probably want to pop some corn and have
**VOLUME UP** (on the player's slider below) for this:

https://user-images.githubusercontent.com/5301131/184541537-99b37fc6-ed5e-46e9-9f99-412a03cb2cb1.mp4

## General Overview

| Version        | Documentation                                         |
| -------------- | ----------------------------------------------------- |
| Unreleased     | https://github.com/lorint/brick/blob/master/README.md |
| 1.0.199        | https://github.com/lorint/brick/blob/v1.0/README.md   |

One core goal behind The Brick is to adhere as closely as possible to Rails conventions.  As
such, models, controllers, and views are treated independently.  You can use this tool to only
auto-build models if you wish, and then make your own controllers and views.  Or have The Brick
auto-build controllers and views for some resources as you fine-tune others with custom code.
Any hybrid way you want to mix and mash that is possible.  The idea is to use The Brick to
automatically flesh out the more tedious and simple parts of your application, freeing up your
time to focus on the more tricky bits.

The default resulting pages built out offer "index" and "show" views for each model, with
references to associated models built out as links.  The index page which lists all records for
a given model creates just one database query in order to get records back -- no "N+1" querying
problem common to other solutions which auto-scaffold related tables of data.  This is due to
the intelligent way in which JOINs are added to the query, even when fields are requested which
are multiple "hops" away from the source table.  This frees up the developer from writing many
tricky ActiveRecord queries.  The approach taken up to version 1.0.91 was fairly successful
except for when custom DSL was used on tables which are self-referencing, for instance with a
DSL of `[name]` on an Employee table which has a `manager_id` column, then the employee's name
and boss' name might show as the same when referenced from a query on a related table at least
one hop away, such as from `orders` (even though obviously the employee and their boss would be
two different records in the same table).  To remedy this, a fully new approach was taken
starting with version 1.0.92 in which the table aliasing logic used by Arel is captured as the
AST tree is being walked, and exact table correlation names are tracked in relation to the
association names in the tree.  This enables a really cool feature for those who work with more
complex ActiveRecord queries that use JOINs -- you can [find table aliases for complex ActiveRecord queries](./docs/find_table_aliases.md).

On the "show" page which is built out, CRUD functionality for an individual record can be
performed.  Date and time fields are made editable with pop-up calendars by using the very lean
"flatpickr" library.

In terms of models, all major ActiveRecord associations are built out, including has_many and
belongs_to, as well as has_many :through, Single Table Inheritance (STI), and polymorphic
associations.  Based on the foreign keys found in the database, appropriate belongs_tos are
built, and corresponding has_many associations as well, being inverses of the discovered
belongs_tos.  From there, any tables which are found to only have belongs_to fields are
considered to be "associative" (or "join") tables, and relevant has_many :through associations
are then added.  For example, if there are recipes and ingredients set up with an associative
table like this:

    Recipe --> RecipeIngredient <-- Ingredient

then first there are two belongs_to associations placed in RecipeIngredient, and then two
corresponding has_manys to go the other "inverse" direction -- one in Recipe, and one in
Ingredient.  Finally with RecipeIngredient being recognised as an associative table (as long as
it has no other columns than those two foreign keys, recipe_id and ingredient_id), then in
Recipe a HMT would automatically be added:

    has_many :ingredients, through: :recipe_ingredients

and in Ingredient another HMT would be added:

    has_many :recipes, through: :recipe_ingredients

So when you run the whole thing you could navigate to https://localhost:3000/recipes, and see
each recipe and also all the ingredients which it requires through its HMT.

If either (or both) of the foreign keys were missing in the database, they could be added into
additional_references.  Say that the foreign key between Recipe and RecipeIngredient is missing.
It can be provided by putting a line like this in an initialiser file:

    ::Brick.additional_references = [['recipe_ingredients', 'recipe_id', 'recipes']]

Brick can auto-create its own initialiser file by doing `rails g brick:install`, and as part of
the process automatically infers missing foreign key references.  These suggestions can fill in
the gaps where belongs_to and has_many associations could exist, but don't yet because of the
missing foreign key.  It does this based on finding column names that look like appropriate key
names, and then makes a commented out suggestion if the data type also matches the primary key's
type.  By un-commenting the ones you would like (or perhaps even all of them), then to The Brick
it will seem as if those foreign keys are present, and from there Rails will provide referential
integrity.

Myriad other settings can be found in `config/initializers/brick.rb`.

Some other fun generators exist as well -- if you'd like to have a set of migration files built
out from an existing database, that can be done by running the generator
`bin/rails g brick:migrations`.  And similarly, models with `bin/rails g brick:models`.  Even
the existing data rows themselves can be captured into a `db/seeds.rb` file -- just run
`bin/rails g brick:seeds`.  More detail on this can be found below under 1.f, 1.g, and 1.h --
the various "Autogenerate ___ Files" sections.

## Table of Contents

<!-- toc -->

- [1. Getting Started](#1-getting-started)
  - [1.a. Compatibility](#1a-compatibility)
  - [1.b. Installation](#1b-installation)
  - [1.c. Displaying an ERD](#1c-displaying-an-erd)
  - [1.d. Exposing an API](#1d-exposing-an-api)
  - [1.e. Using rails g df_export](#1e-using-rails-g-df-export)
  - [1.f. Autogenerate Model Files](#1f-autogenerate-model-files)
  - [1.g. Autogenerate Migration Files](#1g-autogenerate-migration-files)
  - [1.h. Autogenerate Seeds File](#1h-autogenerate-seeds-file)
  - [1.i. Autogenerate Controller Files](#1f-autogenerate-controller-files)
  - [1.j. Autogenerate Migration Files from a Salesforce installation](#1i-autogenerate-migration-files-from-a-salesforce-installation)
  ### 1.i. Autogenerate Migration Files based on a Salesforce WSDL file
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
- [4. Similar Gems](#4-similar-gems)
- [Issues](#issues)
- [Contributing](#contributing)
- [Intellectual Property](#intellectual-property)

<!-- tocstop -->

## 1. Getting Started

### 1.a. Compatibility

| brick          | branch     | tags   | ruby     | activerecord  |
| -------------- | ---------- | ------ | -------- | ------------- |
| unreleased     | master     |        | >= 2.3.5 | >= 3.1, < 7.2 |
| 1.0            | 1-stable   | v1.x   | >= 2.3.5 | >= 3.1, < 7.2 |

Brick will work with Rails 3.1 and onwards, and Rails 4.2.0 and above are officially supported.
Rails 5.2.6, 7.0, and 7.1 are the versions which have been tested most extensively.

Compatibility with major Rails projects is _very_ strong -- this gem can be dropped directly into a
[Mastodon](https://github.com/mastodon/mastodon) / [Canvas LMS](https://github.com/instructure/canvas-lms) /
[railsdevs](https://github.com/joemasilotti/railsdevs.com) / etc project and things will just **WORK**!
Might want to set up an initializer that points things to their own path by using `::Brick.path_prefix = 'admin'`.

When used with _really_ old versions of Rails, 4.x and older, Brick automatically applies various
compatibility patches so it will run under _much_ newer versions of Ruby than would normally be
allowed -- generally Ruby 2.7.8 can work just fine with apps on Rails 3.1 up to 7.1!  It's all due to the various patches put in place as the gem starts up.  This makes it easier to test the broad range of supported versions of ActiveRecord without the headaches of having to use older versions of Ruby.

When using those early versions of Rails, in version 3.1 if you get the error `"time_zone.rb:270: circular argument reference - now (SyntaxError)"` then add this at the very top of
your `application.rb` file:

    require 'brick'

And if you get string frozen errors then try moving back to Ruby 2.6.10.  If you get the error
`"undefined method 'new' for BigDecimal:Class (NoMethodError)"` then try adding this as the last
line in boot.rb:

    require 'brick/compatibility'

These patches not only allow Brick to run, but also will allow many other full Rails apps to run
perfectly fine (and more securely / much faster) by using a newer Ruby.  A few other enhancements
have been provided as well -- for instance, when eager loading related objects using .includes
then normally every column in all tables would be queried:

```
Employee.includes(orders: :order_details)
        .references(orders: :order_details)
```

To get just the columns that you need, The Brick examines a .select() if you provide one, and if
the first member is :_brick_eager_load then this acts as a special flag to turn on "filter mode"
where only the columns you ask for will be returned, often greatly speeding up query execution
and saving RAM on your Rails machine, especially when the columns you don't need happened to have
large amounts of data.

```
Employee.includes(orders: :order_details)
        .references(orders: :order_details)
        .select(:_brick_eager_load, 'employees.first_name', 'orders.order_date', 'order_details.product_id')
```

More information is available in this [discussion post](https://discuss.rubyonrails.org/t/includes-and-select-for-joined-data/81640).

Another enhancement is a smart `.brick_where()` which operates just like ActiveRecord's normal `.where()` with
the addition that if you reference a related table then it automatically adds appropriate `.joins()` entries
for you.  For instance, if you have **Post** that `has_many :user_posts`, and also
`has_many :users, through: :user_posts`, then let's say on the associative model UserPost there is a boolean
for `liked`.  With this, if you wanted to find all posts which a given user had liked, you could do:

```
Post.brick_where('user_posts.user.id' => my_user.id, 'user_posts.liked' => true)
```

And then the resulting SQL would automatically include JOINs for the related tables, and properly reference the
alias names for those tables in the WHERE clause:
```
Post Load (1.6ms)  SELECT "posts".* FROM "posts" INNER JOIN "user_posts" ON "user_posts"."post_id" = "posts"."id" INNER JOIN "users" ON "users"."id" = "user_posts"."user_id" WHERE "users"."id" = $1 AND "user_posts"."liked" = $2 ORDER BY "posts"."id" ASC  [["id", 5], ["liked", true]]
```

The Brick notices when some other gems are present and makes use of them.  For instance, if your
database uses composite primary keys and you are using Rails 7.0 or older, you'll want to add
the **[composite_primary_keys](https://github.com/composite-primary-keys/composite_primary_keys)** gem so that belongs_to and has_many associations will function.
(Try out the [Adventureworks](https://github.com/lorint/AdventureWorks-for-Postgres) sample database to see this in action.) Already when tables and columns are not named in accordance
with Rails' conventions, The Brick does quite a bit to accommodate.  But to get primary and
foreign keys with multiple columns to work then either use Rails 7.1 or newer, or add the
**composite_primary_keys** gem.

Brick adds **CSV** and **Google Sheets** export links when it sees that the **[duty_free](https://github.com/lorint/duty_free)** gem is present.

Brick auto-detects six other "admin panel" type gems in order to automatically build models and resources for them.
Most popular amongst these is old-school **[activeadmin](https://github.com/activeadmin/activeadmin)**,
the "semi-hosted" **[Forest](https://github.com/ForestAdmin/forest-rails)**,
and memory-intensive but good **[rails_admin](https://github.com/railsadminteam/rails_admin/)**.
As well three other newer gems are worth a look -- very fancy and well-supported **[Avo](https://github.com/avo-hq/avo)**,
lean and mean **[Trestle](https://github.com/TrestleAdmin/trestle)**,
and an intriguing snappy little thing **[Motor](https://github.com/motor-admin/motor-admin-rails)**.  Each of these has its own strengths and weaknesses, and Brick allows you to evaluate them all -- even all of them at once in the same project if you want ... this **[reddit post](https://www.reddit.com/r/rails/comments/11cvycg/compare_six_popular_admin_panel_gems_all_at_once/)** has a quick video demonstration if Admin Panels happen to be your thing!
In terms of configuring the most popular ones, by simply adding `gem 'avo'`, bundling, and then `bin/rails g avo:install && bin/rails assets:precompile` then that one's up and going, and for Rails Admin it's `gem 'rails_admin'`, a bundle, and then
`bin/rails g rails_admin:install`.  Same kind of idea for Trestle, Rails Admin, and ActiveAdmin ... and all three of those will also need `gem 'sassc-rails'`.
Just remember that although it might be described in their documentation that you have to scaffold up resource files or
controllers, with Brick that's not necessary since all of this stuff gets auto-generated.  Ends up being the fastest
way to test out various administrative interfaces in any existing Rails app or for any existing database.

Another notable set of compatibility is provided with the multitenancy gem **[Apartment](https://github.com/influitive/apartment)**.  This is
the most popular gem for setting up multiple tenants where each one uses a different database
schema in Postgres.  The Brick is able to recognise this configuration when you place a line
like this in config/initializers/brick.rb:

    Brick.schema_behavior = { multitenant: {} }

If you provide a sample representative tenant schema that is bound to exist then it gets even
a little smarter about things, being able to auto-recognise models being used on the **has_many**
side of polymorphic associations.  For example, if globex_corp is a schema that has a good
representation of data, then you might want to use this line in the brick initialiser:

    Brick.schema_behavior = { multitenant: { schema_to_analyse: 'globex_corp' } }

The way this auto-polymorphic discovery functions is by analysing all existing types in the
*able_type columns of these associations.  For instance, let's say you have an images table with the
columns `imageable_type` and `imageable_id`, and a goal to have the `Image` model get built out
with `belongs_to :imageable, polymorphic: true`.  In that case to properly establish all the
inverse associations of `has_many :images, as: :imageable` in each appropriate model, then
whatever schema you choose here needs to have data present in those polymorphic columns that
represents the full variety of models that should end up getting the `has_many` side of this
polymorphic association.

A few other gems are auto-recognised in order to support data types, such as
[pg_ltree](https://github.com/sjke/pg_ltree)
for hierarchical data sets in Postgres, [RGeo](https://github.com/rgeo/rgeo) for spatial and
geolocation data types, [oracle_enhanced adapter](https://github.com/rsim/oracle-enhanced) for
Oracle databases, and [ActiveUUID](https://github.com/jashmenn/activeuuid) in order
to use uuids with MySQL or Sqlite databases.

### 1.b. Installation

1. Add Brick to your `Gemfile` and bundle.
    ```
    gem 'brick'
    ```
2. To test things, configure database.yml to use any popular adapter of your choosing -- Postgres, MySQL, Trilogy, Oracle, Microsoft SQL Server, or Sqlite3, and point to an existing relational database.  Then from within `bin/rails c` attempt to reference a model by what its normal name might be.  For instance, if you have a `plants` table then just type `Plant.count` and see that automatically a model is built out on-the-fly and the count for this `plants` table is shown.  If you similarly have `products` that relates to `categories` with a foreign key then notice that by referencing `Category` the gem builds out a model which has a **has_many** association called :products.  Without writing any code these associations are all wired up as long as you have proper foreign keys in place.

Even if your table and column names do not follow Rails' conventions, everything still works
because as models are built out then `self.table_name = ` and `self.primary_key = ` entries are
provided as needed.  Likewise, **belongs_to** and **has_many** associations will indicate
which foreign_key and class_name to use whenever anything is non-standard.  Everything just works.

When running `rails s` you can navigate to the resource names shown during startup.  For instance, here
is a look at a fresh Rails 7 project pointed to an Oracle database loaded with Oracle's OE schema.  This
is a sample database with order entry information.  Some tables in this schema have foreign keys over to
tables in the HR schema as well, and all of the resources you can reference are shown as the `rails s` is
starting up:

```
Lorins-Macbook:example_oracle lorin$ bin/rails s
=> Booting Puma
=> Rails 7.1.3 application starting in development
=> Run `rails server --help` for more startup options

Classes that can be built from tables:  Path:
======================================  =====
CategoriesTab                           /categories_tabs
Customer                                /customers
HR::Country                             /hr/countries
HR::Department                          /hr/departments
HR::Employee                            /hr/employees
HR::Job                                 /hr/jobs
HR::JobHistory                          /hr/job_histories
HR::Location                            /hr/locations
Inventory                               /inventories
Order                                   /orders
OrderItem                               /order_items
ProductDescription                      /product_descriptions
ProductInformation                      /product_informations
Promotion                               /promotions
Warehouse                               /warehouses

Classes that can be built from views:  Path:
=====================================  =====
AccountManager                         /account_managers
BombayInventory                        /bombay_inventories
CustomersView                          /customers_views
OcCorporateCustomer                    /oc_corporate_customers
OcCustomer                             /oc_customers
OcInventory                            /oc_inventories
OcOrder                                /oc_orders
OcProductInformation                   /oc_product_informations
OrdersView                             /orders_views
Product                                /products
ProductPrice                           /product_prices
SydneyInventory                        /sydney_inventories
TorontoInventory                       /toronto_inventories

Puma starting in single mode...
...
```

From this it's easy to tell where you can navigate to in the browser -- in order to see everything from
`HR::JobHistory`, just navigate to http://localhost:3000/hr/job_histories.

To configure additional options, such as defining related columns that you want to have act as if they were a foreign key, then you can build out an initializer file for Brick.  The gem automatically provides some suggestions for you based on your current database, so it's useful to make sure your database.yml file is properly configured before continuing.  By using the `install` generator, the file `config/initializers/brick.rb` is automatically written out and here is the command:

    bin/rails g brick:install

Inside the generated file many options exist, for instance if you wish to have a prefix for all auto-generated paths, you can
un-comment the line:

    ::Brick.path_prefix = 'admin'

and it will affect all routes.  In this case, instead of http://localhost:3000/hr/job_histories, you would navigate to http://localhost:3000/admin/hr/job_histories, and so forth for all routes.  This kind of prefix is very useful when you drop **The Brick** into an existing project and want a full set of administration pages tucked away into their own namespace.  If you are placing this in an existing project then as well you might want to add the very intelligent **link_to_brick** form helper into the `<body>` portion of your `layouts/application.html.erb` file like this:

    <%= link_to_brick %>

and then on every page in your site which relates to a resource that can be shown with a Brick-created index or show page, an appropriate auto-calculated link will appear.  The link creation logic first examines the current controller name to see if a resource of the same name exists and can be surfaced by Brick, and if that fails then every instance variable is examined, looking for any which are of class ActiveRecord::Relation or ActiveRecord::Base.  For all of them an index or show link is created, and they end up being rendered with spacing between them.

If you do use `<%= link_to_brick %>` tags and have Brick only loaded in `:development`, you will want to add this block of code in `application.rb` so that when it is running in Production then these tags will have no effect:

```
unless ActiveRecord::Base.respond_to?(:brick_select)
  module ActionView::Helpers::FormTagHelper
    def link_to_brick(*args, **kwargs)
      return
    end
  end
end
```

### 1.c. Displaying an ERD

It is a bit difficult to fully understand how things are associated by only clicking
through data, going from one resource to the next.  So in order to better grasp how everything is associated, you can show a simple ERD diagram to see associations for the resource you're viewing, such as this glimpse of the Salesorderheader model:

![sample ERD for BusinessEntity](./docs/erd1.png)

From this we can see that Salesorderheader **belongs_to** Customer, Address, Salesperson,
Salesterritory, and Shipmethod.  Foreign keys for these associations are listed under
Salesorderheader.  The only model associated with a crow's foot designation is at the far
right, and this symbol indicates that Salesorderdetail is referenced with a **has_many**
association, so the foreign key for this association is found in that foreign table.

Take special note that there are two links to Address -- one called "shiptoaddress" and
the other "billtoaddress".  While not very common, there are times when one record should
be associated to the same model in multiple ways, and as such have multiple foreign keys.
When this is the case, The Brick builds out multiple **belongs_to** associations having
unique names that are derived from the foreign key column names themselves.  Here in
the ERD view it's easy to visualise because when a belongs_to name is not exactly the same
as the resource to which it relates, a label is provided on the links to indicate what name
has been chosen.

Opening one of these ERD diagrams is easy -- from any index view click on the ERD icon
located to the right of the resource name.  A partial ERD diagram will open which shows
immediately adjacent models -- that is, models which are up to one hop away via
**belongs_to** and **has_many** associations.  Crow's foot notation indicates the "one
and only one" and "zero to many" sides of each association as appropriate.

Models related via a **has_many :through**, will show with a dashed line, such as seen
here for the lowermost four models associated to BusinessEntity:

![sample ERD for BusinessEntity](./docs/erd2.png)

(The above diagrams can be seen by installing the Adventureworks sample, adding this to your **initializers/brick.rb** file:
```
::Brick.metadata_columns = ['rowguid', 'modifieddate']
```
and then by navigating to http://localhost:3000/person/businessentities?_brick_erd=1 and http://localhost:3000/sales/salesorderheaders?_brick_erd=1.)

### 1.d. Exposing an API

A [video walkthrough](https://github.com/lorint/brick/blob/master/docs/api.md) is now available!

**The Brick** will automatically create API endpoints when it sees that `::Brick.api_roots=` has been
set with at least one path.  Further, OpenAPI 3.0 compatible documentation becomes available when the
**[rswag-ui gem](https://github.com/rswag/rswag)** has been configured.  With that gem bundled into
your project, configuration for RSwag UI can be automatically put into place by running
`rails g rswag:ui:install`, which performs these two actions:
```
  create  config/initializers/rswag_ui.rb
   route  mount Rswag::Ui::Engine => '/api-docs'
```

By default the documentation endpoint expects YAML, and in the interest of broader compatibility with
OpenAPI it was chosen for **The Brick** to instead provide JSON.  So there is a change necessary to
get things going -- open up `rswag_ui.rb` and change .yaml to .json so it looks something like this:
```
Rswag::Ui.configure do |config|
  config.swagger_endpoint '/api-docs/v1/swagger.json', 'API V1 Docs'
end
```

The API itself gets served from `/api/v1/` by default, and you can change that root path if you
wish by going into the Brick initializer file and uncommenting this entry:

```
# ::Brick.api_roots = ['/api/v1/'] # Paths from which to serve out API resources when the RSwag gem is present
```

With all of this in place, when you run `bin/rails s` then right before the message about the rack
server starting, you should see this indication:
```
Mounting OpenApi 3.0 documentation endpoint for "API V1 Docs" on /api-docs/v1/swagger.json
API documentation now available when navigating to:  /api-docs/index.html
```

And then navigating to http://localhost:3000/api-docs/v1 should look something like this:

![API view of EmployeeDepartmentHistory](./docs/api1.png)

You can test any of the endpoints with the "Try it out" button.

When surfacing database views through the API there's a convenient way to make multiple versions
available -- Brick recognises special naming prefixes to make things as painless as possible.  The
convention to use is to apply `v#_` prefixes to the view names, so `v1_` (or even just `v_`) means the
first version, `v2_` and `v3_` for the second and third versions, etc.  Then if a **v1** version is
provided but not a **v2** version, no worries because when asking for the **v2** version Brick
inherits from the **v1** version.  Technically this is accomplished by creating a route for **v2**
which points back to that older **v1** version of the API controller during Rails startup.  Brick
auto-creates these routes during the same time in which Rails is finalising all the routes.
(Or at the point when `#mount_brick_routes` is called if that is placed within **routes.rb**.)

Perhaps an example will make this whole concept a bit clearer -- say for example you wanted to make
three different versions of an API available.  With **v1** there should only be two views, one for
sales and another for products.  Then in **v2** and **v3** there's another view added for customers.
As well, in **v3** the sales view gets updated with new logic.  At first it might seem as if you would
have to duplicate some of the views to have the **v2** and **v3** APIs render the same sales,
products, and customers info that previous versions do.  But Brick allows you to do this with no
duplicated code, using just 4 views altogether that get inherited.  The magic here is in those `v#_`
prefixes:

| Path     | sales        | products       | customers        |
| -------- | ------------ | -------------- | ---------------- |
| /api/v1/ | **v_sales** | **v1_products** |                  |
| /api/v2/ |              |                | **v2_customers** |
| /api/v3/ | **v3_sales** |                |                  |

With this naming then what actually gets served out is this, and these _italicised_ view names are
the ones that have been inherited from a prior version.

| Path     | sales        | products       | customers        |
| -------- | ------------ | -------------- | ---------------- |
| /api/v1/ | **v_sales**  | **v1_products** |                  |
| /api/v2/ | _v_sales_    | _v1_products_   | **v2_customers** |
| /api/v3/ | **v3_sales** | _v1_products_   | _v2_customers_   |

Some final coolness which you can leverage is with querystring parameters -- API calls allow you to
specify `_brick_order`, `_brick_page`, `_brick_page_size`, and also filtering for any column.  An
example is this request to use API v2 to show page 3 of all products which cost £10, with each page
having 20 items:

`http://localhost:3000/api/v2/products.json?_brick_page=3&_brick_page_size=20&price=10`

In this request, not having specified any column for ordering, by default the system will order by
the primary key if one is available.

### 1.f. Autogenerate Model Files

To create a set of model files from an existing database, you can run this generator:

    bin/rails g brick:models

First a table picker comes up where you choose which table(s) you wish to build models for -- by default all the tables are chosen. (Use the arrow keys and spacebar to select and deselect items in the list), then press ENTER and model files will be written into the app/models folder.

Table and column names do not have to adhere to Rails convention -- singular / plural / uppercase / lower / etc. are all valid, and the resulting model files will properly set self.table_name = '....' and primary_key = '...ID' as appropriate.

On associations it sets the class_name, foreign_key, and for has_many :through the source, and inverse_of when any of those are necessary. If they're not needed (which is pretty common of course when following standard Rails conventions) then it refrains.

Brick also knows how to deal with Postgres schemas, building out modules for anything that's not public, so for a
sales.orders table the model class would become Sales::Order, and the controller Sales::OrdersController, etc.

Special consideration is made when multiple foreign keys go from one table to another so that unique associations
will be created.  For instance, given Flight and Airport tables where Flight has two foreign keys to Airport,
one to define the departure airport and another for the arrival one, with foreign keys named `departure_id` and
`arrival_id`, the belongs_to associations would end up being named **departure_airport** and **arrival_airport**.

### 1.g. Autogenerate Migration Files

If you'd like to have a set of migration files built out from an existing database, that can be done by running this generator:

    bin/rails g brick:migrations

First a table picker comes up where you choose which table(s) you wish to build migrations for -- by default all the tables are chosen. (Use the arrow keys and spacebar to select and deselect items in the list), then press ENTER and new migration files for each individual table in your database are built out either in db/migrate, or if that folder already has .rb files then the destination becomes tmp/brick_migrations.

After successful file generation, the `schema_migrations` table is updated to have appropriate numerical `version` entries, one for each file which was generated.  This is so that after generating, you don't end up seeing the "Migrations are pending" error later.

If you choose to have foreign keys added inline instead of as a final migration, then if you
have a circular reference that prevents Brick from completing the creation of migrations normally,
you will see warning messages similar to this:

```
Can't do customer because:
  store
Can't do inventory because:
  store
Can't do payment because:
  rental, customer, staff
Can't do rental because:
  staff, inventory, customer
Can't do staff because:
  store
Can't do store because:
  manager_staff

*** Created 10 migration files under db/migrate ***
-----------------------------------------
Unable to create migrations for 6 tables.  Here's the top 5 blockers:
[["store", 3], ["staff", 3], ["customer", 2], ["rental", 1], ["inventory", 1]]
```

(This example is what you get with the Sakila database, which has this kind of circular reference.)

In cases such as this there are a couple options -- you can use a special hint in the brick.rb
initializer to act as if one or more foreign keys are not present while running Brick generators,
or you can choose to create all foreign keys as a final migration at the end.

Using the hint in brick.rb will affect both brick:migrations and brick:seeds.  Here is an example
of a deferral which will allow the Sakila database to complete normally, fully avoiding the
litany of "Can't do ___ because" errors shown above:

```
Brick.defer_references_for_generation = [['staff', 'store_id', 'store']]
```

You will often have to either know the foreign key structure pretty well or experiment with deferring
foreign keys to find out the most specific ones to defer in order for these generators to work.

For very large databases it could be simpler to just choose the option to have all the foreign
keys get built as a final migration.

### 1.h. Autogenerate Seeds File

Not unlike the migration generator, you can also generate `db/seeds.rb`.  When you run this:

    bin/rails g brick:seeds

Then the table picker appears.  After choosing the ones that you wish to have contribute to the
`db/seeds.rb` file, all related models are loaded in sequence, starting with "outer" models
which do not have foreign keys to anything, and continuing logically to the next "layer" of
models which then have foreign keys only going to models that so far have been seeded, and so
it continues, layer by layer.  Pretty smart routine that facilitates all of this, and the same
kind of logic is also used for the migrations generator since it has to go in proper sequence
when building out related tables -- first the "outer" ones, and then progressing in to cover
related tables.

In the event that there is a catch-22 situation where a circular reference is present such that
(A) foreign keys in one table rely on another, and (B) in that other there are also keys which
rely upon the one, then your table relations prevent being able to completely seed the data.
In that scenario, all possible seeds up to the catch-22 point are retained, and a note is shown
indicating which models prohibit any further creation of seed data.

When running this against a truly LARGE database, with say millions of rows, consider that the
resulting `db/seeds.rb` file could end up being hundreds of megabytes, or even many gigabytes
in size!  Could feel like it's crashed, but then look in the `db` folder to see if there's a
growing file there, and perhaps it's just still clipping along.  If you let the thing run,
and you have enough disk space, then it should complete and be fully functional.

### 1.i. Autogenerate Controller Files

To create a set of controller files based on existing models, you can run this generator:

    bin/rails g brick:controllers

First a model picker comes up where you choose which model(s) you wish to build controllers for -- by default all existing models are chosen. (Use the arrow keys and spacebar to select and deselect items in the list), then press ENTER and controller files will be written into the app/controllers folder.

Brick also knows how to deal with model namespacing via modules, building out the same controller namespacing with modules as appropriate.

### 1.j. Autogenerate Migration Files based on a Salesforce WSDL file

If you'd like to have a set of migration files built out to match the data structure from an
installation of Salesforce, first obtain the WSDL file, confirm that it has an .xml file
extension, put it into the root of your Rails project, and then run this generator:

    bin/rails g brick:salesforce_migrations

First a choice is shown to pick an XML file.  This is processed with a SAX parser, so it is
read very quickly in order to obtain table and column details.  Once processed, table picker
comes up where you choose which table(s) you wish to build migrations for -- by default all
the tables defined in the WSDL are chosen. Use the arrow keys and spacebar to select and deselect items in the list, then press ENTER and new migration files for each individual table from Salesforce is built out either in db/migrate, or if that folder already has .rb files then the destination becomes tmp/brick_migrations.

When creating a data structure from Salesforce it is almost certain to have circular references,
so you will want to choose the option to create all foreign keys as a last migration.

Because many Salesforce installations have a thousand or more tables, it can become fairly taxing
on your Postgres instance to handle everything.  You will probably need to update postgresql.conf
and increase **max_locks_per_transaction**.  A value of around 500 can work if you have on
the order of a thousand or more tables.  Something on that scale would have at least 3000 foreign
keys in total.

Although the class names and column names do not follow Rails conventions, everything will work,
and this lets you create a Rails app that fully mirrors a Salesforce installation.

## Issues

If you see an error such as this (note the square brackets around the multiple listed keys specialofferid and productid represented):

    PG::UndefinedColumn: ERROR:  column salesorderdetail.["specialofferid", "productid"] does not exist
    LINE 1: ... "sales"."specialofferproduct"."specialofferid" = "sales"."s...

then you probably have a table that uses composite keys.  Thankfully The Brick can make use of
the incredibly popular [composite_primary_keys gem](https://github.com/composite-primary-keys/composite_primary_keys), so just add that to your Gemfile as such:

    gem 'composite_primary_keys'

and then bundle, and all should be well.

---
Every effort is given to maintain compatibility with the current version of the Rails ecosystem,
so if you hit a snag then we'd at least like to understand the situation.  Often we'll also offer
suggestions.  Some feature requests will be entertained, and for things deemed to be outside of
the scope of The Brick, an attempt to provide useful extensibility will be made such that add-ons
can be integrated in order to work in tandem with The Brick.

Please use GitHub's [issue tracker](https://github.com/lorint/brick/issues) to reach out to us.

## Similar Gems

(Are there any???)  A few aspects of **The Brick** resemble Django's [inspectdb](http://docs.djangoproject.com/en/dev/ref/django-admin/#inspectdb)
and Laravel's [RevengeDb](https://github.com/daavelar/reveng-database), and in the Ruby world some
ages ago a cool guy named Dr Nic created a piece of wizardry he called "[magic_models](https://github.com/voraz/dr-nic-magic-models/tree/master)"
which would auto-create models in RAM, along with validators.

When I had met DHH at Rails World in 2023, he indicated that aspects of Brick reminded him of the [Java Naked Objects](http://downloads.nakedobjects.net/resources/Pawson%20thesis.pdf) project from 2004.

On the Admin Panel side of the house,
perhaps [Motor Admin](https://www.getmotoradmin.com/) automates enough things that it comes closest
to being similar to **The Brick**.  But really nothing I'm aware of matches up to everything here,
especially considering all the logic around optimising JOINs to make them fast, or auto-creation of
APIs, or partial ERD diagrams to help navigate, or the support for all flavours of `has_many`
associations.  If you do find anything out there, Rails or not, that resembles any of this, please
let me know because I want to join forces with whoever would create such a thing.

## Contributing

In order to run the examples, first make sure you have Ruby 2.7.x installed, and then:

```
gem install bundler:1.17.3
bundle _1.17.3_
bundle exec appraisal ar-6.1 bundle
DB=sqlite bundle exec appraisal
```

See our [contribution guidelines][5]

## Setting up for PostgreSQL

You should be able to set up the test database for Postgres with:

    DB=postgres bundle exec rake prepare

And run the tests with:

    bundle exec appraisal ar-7.0 rspec spec

## Setting up for MySQL

If you're on Linux:
```
sudo apt-get install default-libmysqlclient-dev
```

Or on OSX / MacOS with Homebrew:
```
brew install mysql
brew services start mysql
```

On an Apple Silicon machine (M1 / M2 / M3 processor) then also set this:
```
bundle config --local build.mysql2 "--with-ldflags=-L$(brew --prefix zstd)/lib"
```

(and maybe even this if the above doesn't work out)
```
bundle config --local build.mysql2 "--with-opt-dir=$(brew --prefix openssl)" "--with-ldflags=-L$(brew --prefix zstd)/lib"
```


Once the MySQL service is up and running you can connect through socket /tmp/mysql.sock like this:
```
mysql -uroot
```

And inside this console now create two users with various permissions (these databases do not need to yet exist).  Trade out "my_username" with your real username, such as "sally@localhost".

    CREATE USER "my_username@localhost" IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON brick_test.* TO "my_username@localhost";
    GRANT ALL PRIVILEGES ON brick_foo.* TO "my_username@localhost";
    GRANT ALL PRIVILEGES ON brick_bar.* TO "my_username@localhost";

    And then create the user "brick" who can only connect locally:
    CREATE USER brick@localhost IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON brick_test.* TO brick@localhost;
    GRANT ALL PRIVILEGES ON brick_foo.* TO brick@localhost;
    GRANT ALL PRIVILEGES ON brick_bar.* TO brick@localhost;
    EXIT

Now you should be able to set up the test database for MySQL with:

    DB=mysql bundle exec rake prepare

And run the tests on MySQL with:

    bundle exec appraisal ar-7.0 rspec spec

## Setting up for Oracle on a MacOS (OSX) machine

Oracle is the third most popular database solution used for Rails projects in production,
so it only makes sense to have support for this in The Brick.  Starting with version 1.0.69
this was added, offering full compatibility for all Brick features.  This can run on Linux,
Windows, and Mac.

One important caveat for those with Apple M1 or M2 machines is that the low-level Ruby driver
which we rely upon will NOT function natively on Apple Silicon, so on an M1 or M2 machine you
will have to use the Rosetta emulator to run Ruby and your entire Rails app.  In the future when
an Apple Silicon version of Oracle Instant Client ships then everything can work natively.

Before setting up the gems, to give support for Oracle in ActiveRecord, there are two necessary
libraries you will need to have installed in order to allow the ruby-oci8 gem to function.
In turn ruby-oci8 is used by oracle_enhanced adapter to give full ActiveRecord support.  Here's
how to get started on a Mac machine that is running Homebrew:

    brew tap InstantClientTap/instantclient
    brew install instantclient-basiclite
    brew install instantclient-sdk

Similar kind of thing on Linux -- install the Basic or Basic Lite version of OCI, and also
the OCI SDK.  With those two libraries in place, you're ready to get the Rails side of things
in order.  Rails has an understanding of the Oracle gem built-in such that if you create a new
Rails app like this:

    rails new brick_app -d oracle

then it automatically puts the main gem in place for you, along with a sample database.yml.

In your Rails project, open your **Gemfile** and confirm that proper database drivers are present:

    gem 'activerecord-oracle_enhanced-adapter'
    gem 'ruby-oci8' # Not needed under Rails 7.x and later
    gem 'brick'

Now bundle, and finally in databases.yml make sure there is an entry which looks like this:

```
development:
  adapter: oracle_enhanced
  database: //localhost:1521/xepdb1
  username: hr
  password: cool_hr_pa$$w0rd
```

You can change **localhost** to be the IP address or host name of an Oracle database server
accessible on your network.  By default Oracle uses port 1521 for connectivity.  The last
part of the database line, in this case **xepdb1**, refers to the name of the database you can
connect to.  If you are unsure, open SQL*Plus and issue this query:

```
SELECT name FROM V$database;
```

The **username** would often refer to the schema you wish to access, or to an account with
privileges on various schemas you are interested in.  The **password** would have been set
up when the user account was first established, and can be reset by logging on as SYSDBA and
issuing this command:

```
ALTER USER hr IDENTIFIED BY cool_hr_pa$$w0rd;
```

This should be all that is necessary in order to have ActiveRecord interact with Oracle.

## Setting up for Microsoft SQL Server on a MacOS (OSX) machine

MSSQL is the fifth most popular database solution used for Rails projects in production, so it
only makes sense to have support for this in The Brick.  Starting with version 1.0.70 this was
added, offering full compatibility for all Brick features.  The client library can run on Linux,
Windows, and Mac.

Before setting up the gems to give support for SQL Server in ActiveRecord, there is a
necessary library you will need to have installed in order to allow the
activerecord-sqlserver-adapter gem to function.  Here's how to get started on a Mac machine
that is running Homebrew:

    brew install freetds
    bundle config set --local build.tiny_tds "--with-opt-dir=$(brew --prefix freetds)"

On Linux it's even simpler -- just install **freetds**.

If you're creating a new application then conveniently Rails already has an understanding of the
SQL Server gem built-in, so if you run this:

    rails new brick_app -d sqlserver

then automatically the main gem is put in place for you, along with a sample database.yml.

In your Rails project, open your **Gemfile** and confirm that proper database drivers are present:

    gem 'activerecord-sqlserver-adapter'
    gem 'tiny_tds'
    gem 'brick'

Now bundle, and finally in databases.yml create an entry which looks like this:

```
development:
  adapter: sqlserver
  encoding: utf8
  username: sa
  password: <%= ENV["SA_PASSWORD"] %>
  host: localhost
```

If your database instance is not the default instance, but instead a named instance, then you
can specify the instance name as part of the **host** parameter like this: **localhost\SQLExpress**.

## Intellectual Property

Copyright (c) 2023 Lorin Thwaits (lorint@gmail.com)
Released under the MIT licence.

[5]: https://github.com/lorint/brick/blob/master/docs/CONTRIBUTING.md
