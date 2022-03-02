DECLARE @name NVARCHAR(255) = 'pReorderColumns'
IF OBJECT_ID(@name, 'p') IS NULL EXEC ('CREATE PROCEDURE ' + @name + ' AS SELECT 1')
GO
ALTER PROCEDURE pReorderColumns (
	@schemaName SYSNAME = 'dbo',
	@table SYSNAME,
	@tempName SYSNAME = NULL,
	@newOrder NVARCHAR(MAX) = NULL
) AS

--Prechecks
DECLARE @schema_id INT = (SELECT schema_id FROM sys.schemas WHERE name = @schemaName)
IF @schema_id IS NULL BEGIN
	RAISERROR ('Schema not found', 16, 1)
	RETURN
END

IF (@tempName IS NULL) BEGIN
	SET @tempName = @table + 'Old'
END

DECLARE @tableObjectId INT
SELECT 
		@tableObjectID = OBJECT_ID, 
		@table = tables.name /*Use the original casing, since SQL is case-insensitive, but case-preserving*/
	FROM sys.tables
	WHERE tables.name = @table AND tables.schema_id = @schema_id

IF (@tableObjectId IS NULL) BEGIN
	RAISERROR ('Table not found', 16, 1)
	RETURN
END

IF (SELECT TOP 1 1 FROM sys.tables WHERE tables.name = @tempName) IS NOT NULL BEGIN
	RAISERROR ('A table with the name of the temp table does exist already. Please specify a different name.', 16, 1)
	RETURN
END
DECLARE @columnsError NVARCHAR(MAX) = NULL

DECLARE @newColumnOrder TABLE (OrderNumber INT NOT NULL UNIQUE, ColumnName NVARCHAR(255) NOT NULL UNIQUE)

--Check the new order of columns
IF @newOrder IS NULL BEGIN
	SET @columnsError = 'Please specify a new column-order (@newOrder)'
END ELSE IF (SELECT TOP 1 1 FROM dbo.fSplit1NVCWithRow(@newOrder, ',') GROUP BY RTRIM(LTRIM(NVC1)) HAVING COUNT(*) > 1) IS NOT NULL BEGIN
	SET @columnsError = 'You specified at least one column twice'
END ELSE BEGIN
	INSERT @newColumnOrder
		SELECT RowNumber, LTRIM(RTRIM(NVC1)) FROM dbo.fSplit1NVCWithRow(@newOrder, ',')
	DECLARE @columnsMissing NVARCHAR(MAX) = NULL
	SELECT @columnsMissing = COALESCE(@columnsMissing + ', ', '') + name FROM sys.columns LEFT JOIN @newColumnOrder AS NewColumnOrder ON NewColumnOrder.ColumnName = columns.name WHERE columns.object_id = @tableObjectId AND NewColumnOrder.ColumnName IS NULL
	IF @columnsMissing IS NOT NULL BEGIN
		SET @columnsError = 'At least one column from the table does not appear in @newOrder: ' + @columnsMissing
	END ELSE BEGIN
		SELECT @columnsMissing = COALESCE(@columnsMissing + ', ', '') + ColumnName FROM @newColumnOrder AS NewColumnOrder LEFT JOIN sys.columns ON columns.name = NewColumnOrder.ColumnName AND columns.object_id = @tableObjectId WHERE columns.column_id IS NULL
		IF @columnsMissing IS NOT NULL BEGIN
			SET @columnsError = 'At least one column from your list does not exist in the table: ' + @columnsMissing
		END
	END
END

IF @columnsError IS NOT NULL BEGIN
	PRINT @columnsError
	--Output error and current columnOrder
	DECLARE @currentColumns NVARCHAR(MAX) = NULL

	SELECT @currentColumns = COALESCE(@currentColumns + ', ', '') + columns.name
		FROM sys.columns WHERE object_id = @tableObjectID		
	ORDER BY columns.column_id

	SELECT @currentColumns
	PRINT 'List of current columns: ' + @currentColumns
	RAISERROR (@columnsError, 16, 1)
	RETURN
END

DECLARE @CompareOrders TABLE (ColumnName SYSNAME, NewOrder INT, OldOrder INT)
--Output to show the changes done.
INSERT @CompareOrders 
	SELECT NewColumnOrder.ColumnName, 
		ROW_NUMBER() OVER (ORDER BY NewColumnOrder.OrderNumber) AS NewOrder, 
		ROW_NUMBER() OVER (ORDER BY columns.column_id) AS OldOrder
	FROM @newColumnOrder AS NewColumnOrder 
		INNER JOIN sys.columns ON columns.object_id = @tableObjectId AND columns.name = NewColumnOrder.ColumnName

SELECT ColumnName,
		CASE 
			WHEN (NewOrder < OldOrder) THEN '-' + CONVERT(NVARCHAR(7), OldOrder - NewOrder) 
			WHEN (NewOrder > OldOrder) THEN '+' + CONVERT(NVARCHAR(7), NewOrder - OldOrder) 
			ELSE '' 
		END AS Changed,
		NewOrder,
		OldOrder
	FROM @CompareOrders	AS CompareOrders
	ORDER BY NewOrder ASC

IF (SELECT TOP 1 1 FROM @CompareOrders WHERE NewOrder != OldOrder) IS NULL BEGIN
	RAISERROR ('You did not change the column-order at all...', 16, 1)
	RETURN
END

--Actual work starts here
DECLARE @defaultCollation NVARCHAR(127) = (SELECT collation_name FROM sys.databases WHERE database_id = DB_ID())
DECLARE @identityColumn NVARCHAR(100) = (SELECT columns.name FROM sys.identity_columns INNER JOIN sys.columns ON columns.object_id = identity_columns.object_id AND columns.column_id = identity_columns.column_id WHERE columns.object_id = @tableObjectId)

DECLARE @statements TABLE(ID INT NOT NULL PRIMARY KEY IDENTITY(1, 1), StatementSource NVARCHAR(MAX) /*For easier debugging only*/, Error NVARCHAR(MAX), DropStatement NVARCHAR(MAX), CreateStatement NVARCHAR(MAX))
--Statements are created in the order the recreation of the table should take place.
--The drop-statements will be executed in reverse.

--This script cannot deal with triggers.
IF (SELECT TOP 1 1 FROM sys.triggers WHERE parent_id = @tableObjectId) IS NOT NULL BEGIN
	RAISERROR ('Error: Tables with triggers are not supported. Please remove the trigger manually and recreate it afterwards.', 16, 1)
END

--Statements for default-constraints
INSERT @statements(StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Default-Constraints',
		CASE WHEN default_constraints.principal_id IS NOT NULL OR default_constraints.schema_id != @schema_id OR default_constraints.[type] != 'D' OR default_constraints.is_ms_shipped != 0 OR default_constraints.is_published != 0 OR default_constraints.is_schema_published != 0 OR default_constraints.is_system_named != 0
		THEN 'Unsupported defaultContraint' ELSE NULL END,
		'ALTER TABLE [' + @schemaName + '].[' + @table + '] DROP CONSTRAINT [' + sys.default_constraints.name + ']',
		'ALTER TABLE [' + @schemaName + '].[' + @table + '] ADD CONSTRAINT [' + sys.default_constraints.name + '] DEFAULT ' + sys.default_constraints.definition + ' FOR [' + sys.columns.name + ']'
		FROM sys.default_constraints
			INNER JOIN sys.columns ON sys.columns.object_id = sys.default_constraints.parent_object_id AND sys.columns.column_id = sys.default_constraints.parent_column_id
		WHERE sys.default_constraints.parent_object_id = @tableObjectId

--Statements for indexes
INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Indexes', 
		CASE WHEN indexes.data_space_id != 1 OR indexes.ignore_dup_key != 0 OR indexes.fill_factor != 0 OR indexes.is_padded != 0 OR indexes.is_disabled != 0 OR indexes.is_hypothetical != 0 OR indexes.allow_row_locks != 1 OR indexes.allow_page_locks != 1 THEN 'Unsupported index found' ELSE NULL END,
		CASE WHEN indexes.is_primary_key = 1 OR indexes.is_unique_constraint = 1 THEN 'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] DROP CONSTRAINT [' + indexes.name + ']' ELSE 'DROP INDEX [' + indexes.name + '] ON [' + @schemaName + '].[' + tables.Name + ']' END,
		CASE WHEN indexes.is_primary_key = 1 THEN
			'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] ADD CONSTRAINT [' + indexes.Name + '] PRIMARY KEY ' + indexes.type_desc + ' (' + LEFT(ColumnDefinitions.Value, LEN(ColumnDefinitions.Value) - 1) + ')' + CASE WHEN indexes.filter_definition IS NOT NULL THEN ' WHERE ' + indexes.filter_definition ELSE '' END
		WHEN indexes.is_unique_constraint = 1 THEN
			'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] ADD CONSTRAINT [' + indexes.Name + '] UNIQUE ' + indexes.type_desc + ' (' + LEFT(ColumnDefinitions.Value, LEN(ColumnDefinitions.Value) - 1) + ')' + CASE WHEN indexes.filter_definition IS NOT NULL THEN ' WHERE ' + indexes.filter_definition ELSE '' END
		ELSE
			'CREATE ' + CASE WHEN indexes.is_unique = 1 THEN 'UNIQUE ' ELSE '' END + (indexes.type_desc COLLATE Latin1_General_CI_AS) + ' INDEX [' + indexes.name + '] ON [' + @schemaName + '].[' + tables.name + '] (' + LEFT(ColumnDefinitions.Value, LEN(ColumnDefinitions.Value)-1) + ')' + CASE WHEN IncludeDefinitions.Value IS NOT NULL THEN 'INCLUDE (' + LEFT(IncludeDefinitions.Value, LEN(IncludeDefinitions.Value)-1) + ')' ELSE '' END + CASE WHEN indexes.filter_definition IS NOT NULL THEN ' WHERE ' + indexes.filter_definition ELSE '' END
		END
		FROM sys.tables
			INNER JOIN sys.indexes ON indexes.object_id = tables.object_id
			OUTER APPLY (SELECT (
				SELECT CASE WHEN (index_columns.key_ordinal = 0 AND index_columns.is_included_column = 0) OR index_columns.partition_ordinal != 0
						THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> Unexpected index-columns (1)'))
						ELSE '[' + columns.name + '] ' + CASE WHEN index_columns.is_descending_key = 0 THEN 'ASC' ELSE 'DESC' END + ',' 
						END AS [text()]
					FROM sys.index_columns 
						INNER JOIN sys.columns ON columns.object_id = @tableObjectId AND columns.column_id = index_columns.column_id
					WHERE index_columns.object_id = @tableObjectId AND index_columns.index_id = indexes.index_id
						AND index_columns.is_included_column = 0
					ORDER BY index_columns.key_ordinal
					FOR XML PATH ('')
					) AS Value) AS ColumnDefinitions
			OUTER APPLY (SELECT (
				SELECT CASE WHEN (index_columns.key_ordinal = 0 AND index_columns.is_included_column = 0) OR index_columns.partition_ordinal != 0
						THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> Unexpected index-columns (2)'))
						ELSE '[' + columns.name + '],' 
						END AS [text()]
					FROM sys.index_columns 
						INNER JOIN sys.columns ON columns.object_id = @tableObjectId AND columns.column_id = index_columns.column_id
					WHERE index_columns.object_id = @tableObjectId AND index_columns.index_id = indexes.index_id
						AND index_columns.is_included_column = 1
					ORDER BY index_columns.index_column_id
					FOR XML PATH ('')
					) AS Value) AS IncludeDefinitions
			WHERE tables.object_id = @tableObjectId
			AND indexes.type_desc != 'HEAP' --That is no real index!

--Statements for check-constraints
INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Check-constraints',
		CASE WHEN check_constraints.principal_id IS NOT NULL OR check_constraints.schema_id != @schema_id OR check_constraints.[type] != 'C' OR check_constraints.is_ms_shipped != 0 OR check_constraints.is_published != 0 OR check_constraints.is_schema_published != 0 OR check_constraints.is_disabled != 0 OR check_constraints.is_not_for_replication != 0 OR check_constraints.is_not_trusted != 0 OR check_constraints.uses_database_collation != 1 OR check_constraints.is_system_named != 0 THEN 'Unsupported CheckConstraint found' ELSE NULL END,
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] DROP CONSTRAINT [' + check_constraints.name + ']',
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] ADD CONSTRAINT [' + check_constraints.name + '] CHECK ' + check_constraints.definition
		FROM sys.check_constraints
			INNER JOIN sys.tables ON tables.object_id = check_constraints.parent_object_id
			WHERE tables.object_id = @tableObjectId

--Statements for outgoing foreign keys
INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Outgoing foreign keys',
		CASE WHEN foreign_keys.principal_id IS NOT NULL OR foreign_keys.schema_id != @schema_id OR foreign_keys.[type] != 'F' OR foreign_keys.is_ms_shipped != 0 OR foreign_keys.is_published != 0 OR foreign_keys.is_schema_published != 0 OR foreign_keys.is_disabled != 0 OR foreign_keys.is_not_for_replication != 0 OR foreign_keys.is_not_trusted != 0 OR foreign_keys.is_system_named != 0 THEN 'Unsupported outgoint foreign key found' ELSE NULL END,
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] DROP CONSTRAINT [' + foreign_keys.name + ']', 
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] ADD CONSTRAINT [' + foreign_keys.name + '] FOREIGN KEY (' + LEFT(ReferencingCols.Value, LEN(ReferencingCols.Value) - 1) + ') REFERENCES [' + TargetSchema.Name + '].[' + TargetTable.name + '](' + LEFT(ReferencedCols.Value, LEN(ReferencedCols.Value) - 1) + ') ON DELETE ' + CASE foreign_keys.delete_referential_action_desc WHEN 'NO_ACTION' THEN 'NO ACTION' WHEN 'CASCADE' THEN 'CASCADE' WHEN 'SET_NULL' THEN 'SET NULL' ELSE '<Error>' END + ' ON UPDATE ' + CASE foreign_keys.update_referential_action_desc WHEN 'NO_ACTION' THEN 'NO ACTION' WHEN 'CASCADE' THEN 'CASCADE' WHEN 'SET_NULL' THEN 'SET NULL' ELSE '<Error>' END
	FROM sys.foreign_keys
		INNER JOIN sys.tables ON tables.object_id = sys.foreign_keys.parent_object_id
		INNER JOIN sys.tables AS TargetTable ON TargetTable.object_id = sys.foreign_keys.referenced_object_id
		INNER JOIN sys.schemas AS TargetSchema ON TargetTable.schema_id = TargetSchema.schema_id
		OUTER APPLY (SELECT (
			SELECT '[' + columns.name + '],' AS [text()]
				FROM sys.foreign_key_columns
				INNER JOIN sys.columns ON columns.object_id = foreign_key_columns.parent_object_id AND columns.column_id = foreign_key_columns.parent_column_id
				WHERE foreign_key_columns.constraint_object_id = foreign_keys.object_id
				ORDER BY foreign_key_columns.constraint_column_id
				FOR XML PATH ('')
		) AS Value) AS ReferencingCols
		OUTER APPLY (SELECT (
			SELECT '[' + columns.name + '],' AS [text()]
				FROM sys.foreign_key_columns
				INNER JOIN sys.columns ON columns.object_id = foreign_key_columns.referenced_object_id AND columns.column_id = foreign_key_columns.referenced_column_id
				WHERE foreign_key_columns.constraint_object_id = foreign_keys.object_id
				ORDER BY foreign_key_columns.constraint_column_id
				FOR XML PATH ('')
		) AS Value) AS ReferencedCols
	WHERE tables.object_id = @tableObjectId

--Statements for incoming foreign keys
INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Incoming foreign keys',
		CASE WHEN foreign_keys.principal_id IS NOT NULL OR foreign_keys.schema_id != @schema_id OR foreign_keys.[type] != 'F' OR foreign_keys.is_ms_shipped != 0 OR foreign_keys.is_published != 0 OR foreign_keys.is_schema_published != 0 OR foreign_keys.is_disabled != 0 OR foreign_keys.is_not_for_replication != 0 OR foreign_keys.is_not_trusted != 0 OR foreign_keys.is_system_named != 0 THEN 'Unsupported incoming foreign key found' ELSE NULL END,
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] DROP CONSTRAINT [' + foreign_keys.name + ']', 
		'ALTER TABLE [' + @schemaName + '].[' + tables.name + '] ADD CONSTRAINT [' + foreign_keys.name + '] FOREIGN KEY (' + 
			LEFT(ReferencingCols.Value, LEN(ReferencingCols.Value) - 1) + 
		') REFERENCES [' + TargetSchema.name + '].[' + TargetTable.name + '](' + LEFT(ReferencedCols.Value, LEN(ReferencedCols.Value) - 1) + ') ON DELETE ' + CASE foreign_keys.delete_referential_action_desc WHEN 'NO_ACTION' THEN 'NO ACTION' WHEN 'CASCADE' THEN 'CASCADE' WHEN 'SET_NULL' THEN 'SET NULL' ELSE '<Error>' END + ' ON UPDATE ' + CASE foreign_keys.update_referential_action_desc WHEN 'NO_ACTION' THEN 'NO ACTION' WHEN 'CASCADE' THEN 'CASCADE' WHEN 'SET_NULL' THEN 'SET NULL' ELSE '<Error>' END
	FROM sys.foreign_keys
		INNER JOIN sys.tables ON tables.object_id = sys.foreign_keys.parent_object_id
		INNER JOIN sys.tables AS TargetTable ON TargetTable.object_id = sys.foreign_keys.referenced_object_id
		INNER JOIN sys.schemas AS TargetSchema ON TargetTable.schema_id = TargetSchema.schema_id
		OUTER APPLY (SELECT (
			SELECT '[' + columns.name + '],' AS [text()]
				FROM sys.foreign_key_columns
				INNER JOIN sys.columns ON columns.object_id = foreign_key_columns.parent_object_id AND columns.column_id = foreign_key_columns.parent_column_id
				WHERE foreign_key_columns.constraint_object_id = foreign_keys.object_id
				ORDER BY foreign_key_columns.constraint_column_id
				FOR XML PATH ('')
		) AS Value) AS ReferencingCols
		OUTER APPLY (SELECT (
			SELECT '[' + columns.name + '],' AS [text()]
				FROM sys.foreign_key_columns
				INNER JOIN sys.columns ON columns.object_id = foreign_key_columns.referenced_object_id AND columns.column_id = foreign_key_columns.referenced_column_id
				WHERE foreign_key_columns.constraint_object_id = foreign_keys.object_id
				ORDER BY foreign_key_columns.constraint_column_id
				FOR XML PATH ('')
		) AS Value) AS ReferencedCols
	WHERE TargetTable.object_id = @tableObjectID AND TargetTable.object_id != tables.object_id /* Selbstreferenzen werden von ausgehenden Fremdschlüsseln behandelt */

--Statements for incoming views.
DECLARE @viewObjectIDs TABLE(object_id INT NOT NULL)
INSERT @viewObjectIDs
	SELECT DISTINCT 
			CASE WHEN 
				sql_expression_dependencies.referencing_minor_id != 0 
				OR sql_expression_dependencies.referencing_class != 1
				OR sql_expression_dependencies.referenced_class != 1
				OR sql_expression_dependencies.referenced_server_name IS NOT NULL 
				OR sql_expression_dependencies.referenced_database_name IS NOT NULL 
				OR sql_expression_dependencies.is_caller_dependent = 1 
				OR sql_expression_dependencies.is_ambiguous = 1 THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, 'Unsupported sql_expression_dependencies'))
			ELSE 
				views.object_id
		END
			FROM sys.sql_expression_dependencies
				INNER JOIN sys.tables ON tables.object_id = sql_expression_dependencies.referenced_id
				INNER JOIN sys.views ON views.object_id = sql_expression_dependencies.referencing_id
			WHERE tables.object_id = @tableObjectID
			AND sql_expression_dependencies.referenced_minor_id = 0

INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Views', 
		CASE WHEN views.principal_id IS NOT NULL OR views.[type] != 'V' OR views.is_ms_shipped = 1 OR views.is_published = 1 OR views.is_schema_published = 1 OR views.is_replicated = 1 OR views.has_replication_filter = 1 OR views.has_opaque_metadata = 1 OR views.has_unchecked_assembly_data = 1 OR views.with_check_option = 1 OR views.is_date_correlation_view = 1 OR views.is_tracked_by_cdc = 1 THEN 'Unsupported view found' ELSE NULL END,
		'DROP VIEW [' + schemas.name + '].[' + views.name + ']', 
		OBJECT_DEFINITION(views.object_id)
		FROM @viewObjectIDs AS ViewIDs
			INNER JOIN sys.views ON views.object_id = ViewIDs.object_id
			INNER JOIN sys.schemas ON views.schema_id = schemas.schema_id

--Statements for indexes on incoming views.
INSERT @statements (StatementSource, Error, DropStatement, CreateStatement)
	SELECT 
		'Indexes on views',
		CASE WHEN indexes.data_space_id != 1 OR indexes.ignore_dup_key != 0 OR indexes.fill_factor != 0 OR indexes.is_padded != 0 OR indexes.is_disabled != 0 OR indexes.is_hypothetical != 0 OR indexes.allow_row_locks != 1 OR indexes.allow_page_locks != 1 THEN 'Unsupported index found' ELSE NULL END,
		CASE WHEN indexes.is_primary_key = 1 THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> There cannot be a primary key on a view.')) WHEN indexes.is_unique_constraint = 1 THEN 'ALTER TABLE [' + @schemaName + '].[' + views.name + '] DROP CONSTRAINT [' + indexes.name + ']' ELSE 'DROP INDEX [' + indexes.name + '] ON [' + schemas.name + '].[' + views.Name + ']' END,
		CASE WHEN indexes.is_primary_key = 1 THEN
			CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> There cannot be a primary key on a view.'))
		WHEN indexes.is_unique_constraint = 1 THEN
			'ALTER TABLE [' + schemas.name + '].[' + views.name + '] ADD CONSTRAINT [' + indexes.Name + '] UNIQUE ' + indexes.type_desc + ' (' + LEFT(ColumnDefinitions.Value, LEN(ColumnDefinitions.Value) - 1) + ')' + CASE WHEN indexes.filter_definition IS NOT NULL THEN ' WHERE ' + indexes.filter_definition ELSE '' END
		ELSE
			'CREATE ' + CASE WHEN indexes.is_unique = 1 THEN 'UNIQUE ' ELSE '' END + (indexes.type_desc COLLATE Latin1_General_CI_AS) + ' INDEX [' + indexes.name + '] ON [' + schemas.name + '].[' + views.name + '] (' + LEFT(ColumnDefinitions.Value, LEN(ColumnDefinitions.Value)-1) + ')' + CASE WHEN IncludeDefinitions.Value IS NOT NULL THEN 'INCLUDE (' + LEFT(IncludeDefinitions.Value, LEN(IncludeDefinitions.Value)-1) + ')' ELSE '' END + CASE WHEN indexes.filter_definition IS NOT NULL THEN ' WHERE ' + indexes.filter_definition ELSE '' END
		END
			FROM @viewObjectIDs AS ViewObjectIDs
			INNER JOIN sys.views ON views.object_id = ViewObjectIDs.object_id
			INNER JOIN sys.schemas ON views.schema_id = schemas.schema_id
			INNER JOIN sys.indexes ON indexes.object_id = views.object_id
			OUTER APPLY (SELECT (
				SELECT CASE WHEN (index_columns.key_ordinal = 0 AND index_columns.is_included_column = 0) OR index_columns.partition_ordinal != 0
						THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> Unexpected index-columns (3)'))
						ELSE '[' + columns.name + '] ' + CASE WHEN index_columns.is_descending_key = 0 THEN 'ASC' ELSE 'DESC' END + ',' 
						END AS [text()]
					FROM sys.index_columns 
						INNER JOIN sys.columns ON columns.object_id = sys.views.object_id AND columns.column_id = index_columns.column_id
					WHERE index_columns.object_id = sys.views.object_id AND index_columns.index_id = indexes.index_id
						AND index_columns.is_included_column = 0
					ORDER BY index_columns.key_ordinal
					FOR XML PATH ('')
					) AS Value) AS ColumnDefinitions
			OUTER APPLY (SELECT (
				SELECT CASE WHEN (index_columns.key_ordinal = 0 AND index_columns.is_included_column = 0) OR index_columns.partition_ordinal != 0
						THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> Unexpected index-columns (4)'))
						ELSE '[' + columns.name + '],' 
						END AS [text()]
					FROM sys.index_columns 
						INNER JOIN sys.columns ON columns.object_id = sys.views.object_id AND columns.column_id = index_columns.column_id
					WHERE index_columns.object_id = sys.views.object_id AND index_columns.index_id = indexes.index_id
						AND index_columns.is_included_column = 1
					ORDER BY index_columns.index_column_id
					FOR XML PATH ('')
					) AS Value) AS IncludeDefinitions

--The actual definition of the columns
DECLARE @columnDefinitions NVARCHAR(MAX) = 
	(SELECT (
			SELECT 
				CASE WHEN (columns.is_ansi_padded = 1 AND columns.system_type_id NOT IN (175, 167, 173, 239, 165, 231)) OR (columns.is_ansi_padded = 0 AND columns.system_type_id IN (175, 167, 173, 239, 165, 231)) OR columns.is_rowguidcol != 0 OR columns.is_filestream != 0 OR columns.is_replicated != 0 OR columns.is_non_sql_subscribed != 0 OR columns.is_merge_published != 0 OR columns.is_dts_replicated != 0 OR columns.is_xml_document != 0 OR columns.xml_collection_id != 0 OR columns.rule_object_id != 0 OR columns.is_sparse != 0 OR columns.is_column_set != 0
				THEN CONVERT(NVARCHAR(MAX), CONVERT(INT, '<Error> Unexpected column found: ' + columns.name))
				ELSE 
					'[' + columns.name + '] ' +
						CASE 
							WHEN columns.is_computed = 1 THEN 'AS ' + computed_columns.definition + (CASE WHEN computed_columns.is_persisted = 1 THEN ' PERSISTED' ELSE '' END) 
							ELSE
								CASE 
									WHEN types.name IN ('nvarchar', 'nchar', 'ntext') AND columns.max_length = -1 THEN UPPER(types.name) + '(MAX)' + CASE WHEN columns.collation_name COLLATE Latin1_General_BIN2 != @defaultCollation THEN ' COLLATE ' + columns.collation_name ELSE '' END
									WHEN types.name IN ('nvarchar', 'nchar', 'ntext') AND columns.max_length != -1 THEN UPPER(types.name) + '(' + CONVERT(NVARCHAR(100), columns.max_length/2) +')' + CASE WHEN columns.collation_name COLLATE Latin1_General_BIN2 != @defaultCollation THEN ' COLLATE ' + columns.collation_name ELSE '' END
									WHEN types.name IN ('varchar', 'char', 'text', 'binary', 'varbinary')  AND columns.max_length = -1 THEN UPPER(types.name) + '(MAX)' + CASE WHEN columns.collation_name COLLATE Latin1_General_BIN2 != @defaultCollation THEN ' COLLATE ' + columns.collation_name ELSE '' END
									WHEN types.name IN ('varchar', 'char', 'text', 'binary', 'varbinary') AND columns.max_length != -1 THEN UPPER(types.name) + '(' + CONVERT(NVARCHAR(100), columns.max_length) +')' + CASE WHEN columns.collation_name COLLATE Latin1_General_BIN2 != @defaultCollation THEN ' COLLATE ' + columns.collation_name ELSE '' END
									WHEN types.name IN ('decimal') THEN 'DECIMAL (' + CONVERT(NVARCHAR(100), columns.precision) + ', ' + CONVERT(NVARCHAR(100), columns.scale) + ')'
									ELSE UPPER(types.name)
								END + ' ' +
								CASE WHEN columns.is_nullable = 1 THEN 'NULL' ELSE 'NOT NULL' END + 
								CASE WHEN columns.name = @identityColumn THEN ' IDENTITY(' + COALESCE(CONVERT(NVARCHAR(MAX), identity_columns.seed_value), '<böser Fehler>') + ', ' + COALESCE(CONVERT(NVARCHAR(MAX), identity_columns.increment_value), '<böser Fehler>') + ')' ELSE '' END
						END +
						', ' 
				END AS [text()]
				FROM sys.columns
				INNER JOIN sys.tables ON columns.object_id =  tables.object_id 
				INNER JOIN sys.types ON columns.user_type_id = types.user_type_id
				LEFT JOIN sys.identity_columns ON identity_columns.object_id = tables.object_id AND identity_columns.column_id = columns.column_id
				LEFT JOIN sys.computed_columns ON computed_columns.object_id = columns.object_id AND computed_columns.column_id = columns.column_id
				LEFT JOIN @newColumnOrder AS NewColumnOrder ON NewColumnOrder.ColumnName = columns.name
				WHERE tables.object_id = @tableObjectId
				ORDER BY NewColumnOrder.OrderNumber
				FOR XML PATH ('')
		))
		
--Select-statement for all columns
DECLARE @selectColumnsOldTable NVARCHAR(MAX) = 
	(SELECT (
			SELECT '[' + columns.name + '], ' AS [text()]
				FROM sys.columns
				INNER JOIN sys.tables ON columns.object_id =  tables.object_id 
				INNER JOIN sys.types ON columns.user_type_id = types.user_type_id
				LEFT JOIN @newColumnOrder AS NewColumnOrder ON NewColumnOrder.ColumnName = columns.name
				WHERE tables.object_id = @tableObjectId
					AND sys.columns.is_computed = 0
				ORDER BY NewColumnOrder.OrderNumber
				FOR XML PATH ('')
		))

IF (SELECT TOP 1 1 FROM @statements	WHERE DropStatement LIKE '%<Error>%' OR CreateStatement LIKE '%<Error>%' OR Error IS NOT NULL) IS NOT NULL BEGIN
	SELECT TOP 1 * FROM @statements	WHERE DropStatement LIKE '%<Error>%' OR CreateStatement LIKE '%<Error>%' OR Error IS NOT NULL
	RAISERROR ('There have been some errors!', 16, 1)
	RETURN
END ELSE BEGIN
	--Collect the statements that will be executed.
	DECLARE @actualStatements TABLE(ID INT NOT NULL PRIMARY KEY, StatementText NVARCHAR(MAX) NULL, SpecialStatementType NVARCHAR(127) NULL)
	DECLARE @statementCount INT = (SELECT COUNT(*) FROM @statements)

	INSERT @actualStatements
		SELECT ROW_NUMBER() OVER(ORDER BY ID DESC), DropStatement, NULL FROM @statements

	INSERT @actualStatements VALUES (@statementCount + 1, NULL, 'BEGIN TRANSACTION')
	INSERT @actualStatements VALUES (@statementCount + 2, 'EXEC sp_rename @objname = ''[' + @schemaName + '].[' + @table + ']'', @newname = ''' + @tempName + '''', NULL)
	IF @identityColumn IS NOT NULL BEGIN
		INSERT @actualStatements VALUES (@statementCount + 3, NULL, 'GetIdentCurrent')
	END
	INSERT @actualStatements VALUES (@statementCount + 4, 'CREATE TABLE [' + @schemaName + '].[' + @table + '] (' + LEFT(@columnDefinitions, LEN(@columnDefinitions) - 1) + ')', NULL)
	DECLARE @copyData NVARCHAR(MAX) = ''
	IF @identityColumn IS NOT NULL BEGIN
		SET @copyData = @copyData + 'SET IDENTITY_INSERT [' + @table + '] ON; '
	END
	SET @copyData = @copyData + 'INSERT [' + @table + '] (' + LEFT(@selectColumnsOldTable, LEN(@selectColumnsOldTable)-1) + ') SELECT ' + LEFT(@selectColumnsOldTable, LEN(@selectColumnsOldTable)-1) + ' FROM [' + @tempName + '];'
	IF @identityColumn IS NOT NULL BEGIN
		SET @copyData = @copyData + ' SET IDENTITY_INSERT [' + @table + '] OFF'
	END
	INSERT @actualStatements VALUES (@statementCount + 5, @copyData, NULL)
	INSERT @actualStatements VALUES (@statementCount + 6, 'DROP TABLE ' + @tempName, NULL)

	IF @identityColumn IS NOT NULL BEGIN
		INSERT @actualStatements VALUES (@statementCount + 7, NULL, 'Reseed')
	END

	INSERT @actualStatements VALUES (@statementCount + 8, NULL, 'COMMIT TRANSACTION')

	INSERT @actualStatements SELECT ROW_NUMBER() OVER(ORDER BY ID ASC) + @statementCount + 100, CreateStatement, NULL FROM @statements

	--Output the statements that will be executed one by one:
	PRINT 'The following statements will be executed one by one:'
	DECLARE @toExecute NVARCHAR(MAX)
	DECLARE @specialStatementType NVARCHAR(127)
	DECLARE @inTransaction BIT = 0
	DECLARE @identCurrentHasBeenRead BIT = 0
	DECLARE execCursor CURSOR FOR SELECT StatementText, SpecialStatementType FROM @actualStatements ORDER BY ID ASC
	OPEN execCursor
	FETCH NEXT FROM execCursor INTO @toExecute, @specialStatementType
	WHILE @@FETCH_STATUS = 0 BEGIN
		IF @specialStatementType = 'BEGIN TRANSACTION' BEGIN
			IF @inTransaction = 1 BEGIN
				RAISERROR ('Transaction is already running (1).', 16, 1)
				RETURN
			END
			SET @inTransaction = 1
			PRINT 'BEGIN TRANSACTION'
		END ELSE IF @specialStatementType = 'COMMIT TRANSACTION' BEGIN
			IF @inTransaction = 0 BEGIN
				RAISERROR ('No transaction has been started yet (1).', 16, 1)
				RETURN
			END
			SET @inTransaction = 0
			PRINT 'COMMIT TRANSACTION'
		END ELSE IF @specialStatementType = 'GetIdentCurrent' BEGIN
			IF @identCurrentHasBeenRead = 1 BEGIN
				RAISERROR ('IdentCurrent has already been retrieved.', 16, 1)
				RETURN
			END
			PRINT N'SET @identCurrent = IDENT_CURRENT(''[' + @schemaName + '].[' + @tempName + ']'')'
			SET @identCurrentHasBeenRead = 1
		END ELSE IF @specialStatementType = 'Reseed' BEGIN
			IF @identCurrentHasBeenRead = 0 BEGIN
				RAISERROR ('IdentCurrent has not yet been retrieved.', 16, 1)
				RETURN
			END
			PRINT 'DBCC CHECKIDENT ([' + @schemaName + '.' + @table + '], RESEED, @identCurrent);'
		END ELSE BEGIN
			IF @toExecute IS NULL BEGIN
				PRINT '@specialStatementType == ' + COALESCE(@specialStatementType, '<NULL>')
				RAISERROR ('@toExecute should not be NULL here.', 16, 1)
				RETURN
			END
			PRINT @toExecute
		END

		FETCH NEXT FROM execCursor INTO @toExecute, @specialStatementType
	END
	CLOSE execCursor
	DEALLOCATE execCursor
	IF @inTransaction = 1 BEGIN
		RAISERROR ('The transaction was not committed (1).', 16, 1)
		RETURN
	END

	PRINT 'Actual execution starts now'
	DECLARE @identCurrent INT = NULL
	DECLARE execCursor CURSOR FOR SELECT StatementText, SpecialStatementType FROM @actualStatements ORDER BY ID ASC
	OPEN execCursor
	FETCH NEXT FROM execCursor INTO @toExecute, @specialStatementType
	WHILE @@FETCH_STATUS = 0 BEGIN
		IF @specialStatementType = 'BEGIN TRANSACTION' BEGIN
			IF @inTransaction = 1 BEGIN
				PRINT 'Executing a rollback'
				ROLLBACK TRANSACTION
				RAISERROR ('Transaction is already running (2).', 16, 1)
				RETURN
			END
			SET @inTransaction = 1
			PRINT 'BEGIN TRANSACTION'
			BEGIN TRANSACTION
		END ELSE IF @specialStatementType = 'COMMIT TRANSACTION' BEGIN
			IF @inTransaction = 0 BEGIN
				RAISERROR ('No transaction has been started yet (2).', 16, 1)
				RETURN
			END
			SET @inTransaction = 0
			PRINT 'COMMIT TRANSACTION'
			COMMIT TRANSACTION
		END ELSE IF @specialStatementType = 'GetIdentCurrent' BEGIN
			IF @identCurrent IS NOT NULL BEGIN
				RAISERROR ('IdentCurrent has already been retrieved.', 16, 1)
				RETURN
			END
			SET @toExecute = N'SET @identCurrent = IDENT_CURRENT(''[' + @schemaName + '].[' + @tempName + ']'')'
			PRINT 'Executing: ' + @toExecute
			DECLARE @paramDefinition NVARCHAR(MAX) = N'@identCurrent INT OUTPUT';
			EXEC sp_executesql @toExecute, @paramDefinition, @identCurrent = @identCurrent OUTPUT;
			IF @@ERROR <> 0 BEGIN
				IF @inTransaction = 1 BEGIN
					PRINT 'An error occurred inside the transaction. Starting rollback and exiting.'
					ROLLBACK TRANSACTION
					RETURN
				END ELSE BEGIN
					PRINT 'An error occurred outside of a transaction. Exiting.'
					RETURN
				END
			END
			PRINT 'Current identity is: ' + CONVERT(NVARCHAR(MAX), @identCurrent)
		END ELSE IF @specialStatementType = 'Reseed' BEGIN
			IF @identCurrent IS NULL BEGIN
				RAISERROR ('IdentCurrent has not yet been retrieved.', 16, 1)
				RETURN
			END
			SET @toExecute = 'DBCC CHECKIDENT ([' + @schemaName + '.' + @table + '], RESEED, ' + CONVERT(NVARCHAR(MAX), @identCurrent) + ');' --For some reason, Checkident requires a different format that does not allow brackets between schema and table, but requires the on the outside.
			PRINT 'Executing : ' + @toExecute
			EXEC sp_executesql @statement = @toExecute
			IF @@ERROR <> 0 BEGIN
				IF @inTransaction = 1 BEGIN
					PRINT 'An error occurred inside the transaction. Starting rollback and exiting.'
					ROLLBACK TRANSACTION
					RETURN
				END ELSE BEGIN
					PRINT 'An error occurred outside of a transaction. Exiting.'
					RETURN
				END
			END
		END ELSE BEGIN
			PRINT 'Executing: ' + @toExecute
			EXEC sp_executesql @statement = @toExecute
			IF @@ERROR <> 0 BEGIN
				IF @inTransaction = 1 BEGIN
					PRINT 'An error occurred inside the transaction. Starting rollback and exiting.'
					ROLLBACK TRANSACTION
					RETURN
				END ELSE BEGIN
					PRINT 'An error occurred outside of a transaction. Exiting.'
					RETURN
				END
			END
		END
		FETCH NEXT FROM execCursor INTO @toExecute, @specialStatementType
	END
	CLOSE execCursor
	DEALLOCATE execCursor
	IF @inTransaction = 1 BEGIN
		PRINT 'Executing a rollback'
		ROLLBACK TRANSACTION
		RAISERROR ('The transaction was not committed (2).', 16, 1)
		RETURN
	END
END
