# reorder-columns
This mini-project should offer an easy way to reorder columns in an existing table on sql-server.
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
- All types of columns
  - Identity-columns (only of type (1,1))
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

## Versions of Sql-Server
Currently, this is only tested in SqlServer 2008 R2. Please feel free to let me know if it works in other versions as well - or provide a patch that makes it work.
