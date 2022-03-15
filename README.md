# reorder-columns
This mini-project should offer an easy script-only-way to reorder columns in an existing table on sql-server. We all know this: Over the years, new columns are always added to the right end of a table. And when debugging the application then, you have to scroll far the right to get the important information.

For a single database that you access directly, SSMS seems to be able to do that. I never tried that, since all our databases are only deployed and updated using scripts. And that's why I wrote this script: It automates the process of recreating the table with the new order of the columns.

It's very easy to use:
Download and execute fSplit1NVCWithRow.sql and pReorderColumns.sql.
Then you can easily reorder the columns of any table by using pReorderColumns.
You can find an example in Example.sql.

## How it works
- The script analyses the existing table and it's relations to other tables and views.
- All relations are deleted then.
- The existing table is then renamed to a temporary name.
- A new table is created with the new order of columns.
- All data is copied
- All relations to other tables and views are created again.

## Supported features
- All data-types of columns
  - Identity-columns (but only of type (1,1))
- Default-constraints
- Check-constraints
- Foreign keys
  - Incoming from other tables
  - Outgoing to other tables
  - ON DELETE CASCADE
  - ON UPDATE CASCADE
- Indexes
  - Nonclustered and clustered
  - Unique and non-unique
  - Partial indexes (WHERE ...)
  - Indexes with INCLUDE
- Views
  - Recreate views that reference the table
  - Does also work for indexed views

If you miss anything, please feel free to add it and let me know.

## Caveats
- For the whole process, the table has to be taken offline.
- If you use "SELECT * FROM", the order of columns does change of course. So check your code!
- If you use sql-features, that are not yet supported by this script, they will probably be lost during execution. So please check you schema after running the script.

## Versions of Sql-Server
Currently, this is tested in SqlServers 2016, 2017 and 2019. Please feel free to let me know if it works in other versions as well - or provide a patch that makes it work.
