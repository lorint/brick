## Instantly create an API from any existing database

Pop some corn and have **VOLUME UP** (on the player's slider below) for this video walkthrough:

https://user-images.githubusercontent.com/5301131/213583650-91256f35-ee03-4cec-abec-e5a9191508f5.mp4

Shown here is an inheritance example which relates to this kind of setup:

When surfacing database views through the API there's a convenient way to make multiple versions
available -- Brick recognises special naming prefixes to make things as painless as possible.  The
convention to use is to apply `v#_` prefixes to the view names, so `v1_` (or even just `v_`) means the
first version, `v2_` and `v3_` for the second and third versions, etc.  Then if a **v1** version is
provided but not a **v2** version, no worries because when asking for the **v2** version Brick
inherits from the **v1** version.  Technically this is accomplished by creating a route for **v2**
which points back to that older **v1** version of the API controller during Rails startup.  Brick
auto-creates these routes during the same time in which Rails is finalising all the routes.

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

Eager to hear your feedback on this new feature!
