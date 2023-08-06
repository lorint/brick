## Find table aliases for complex ActiveRecord queries

On a Ruby message board [Abdullah Almanie](https://github.com/Abdullah-l) asked a question that reminded me of a
cool internal feature that I hadn't documented yet, so it's not very well known.  Say you have models for
**customers**, **orders**, and **employees**.  As well, each employees' boss can be looked up using a
self-referencing join in Employee called `reports_to`.  Then if you were to run something like this:

    details = Customer.joins({ orders: { employee: :reports_to} } )

Then this kind of SQL might result:

```
SELECT "customers".* FROM "customers"
 INNER JOIN "orders" ON "orders"."customer_id" = "customers"."id"
 INNER JOIN "employees" ON "employees"."id" = "orders"."employee_id"
 INNER JOIN "employees" "reports_tos_employees" ON "reports_tos_employees"."id" = "employees"."reports_to_id"
```

But before executing the query, can you know what kind of table alias names would get chosen by Arel?  For instance,
in this case when **employees** is JOINed to itself, how easy would it be to predict that Arel would create the
query with a correlation name of `reports_tos_employees` the second time the **employees** table is referenced?
Many folks just run the query in order to find what Arel ends up choosing for weird alias names.  And between
different versions of ActiveRecord you can get differing results, so upgrading your code base could mean that you
break one of these if it was hard-coded.  As such, wouldn't it be cool to be able to track that before the query is run?

Now you can!

Just run `#brick_links` on an ActiveRecord::Relation to get a special lookup hash back:

```
details.brick_links
# => {""=>"customers",
 "orders.employee.reports_to"=>"reports_tos_employees",
 "orders.employee"=>"employees",
 "orders"=>"orders"}
```

Notice that the keys in this hash end up as dot-separated "paths" and use the same association names that you would
normally use to refer to an associated object ... so for instance, to get the boss's first name from a detail, you
might do something like this:

    details.first.orders.first.employee.reports_to.first_name

And then if you wanted to know the exact table alias that ends up in the SQL for any reason, such as to put it in a
`.select()` or `.where()` or whatever, you can do this:

```
details.brick_links["orders.employee.reports_to"]
# => "reports_tos_employees"
```

This works on any ActiveRecord Relation object, and with pretty much any crazy complexity of JOINs.  Under the hood
what it's doing is capturing the real alias names of tables that get chosen while the Arel tree is being walked.
