--Just a utility-function
DECLARE @name NVARCHAR(255) = 'fSplit1NVCWithRow'
IF OBJECT_ID(@name) IS NULL EXEC ('CREATE FUNCTION ' + @name + ' (@i INT) RETURNS @x TABLE(I INT) AS BEGIN RETURN END')
GO
ALTER FUNCTION fSplit1NVCWithRow (
	@srcNVC1 NVARCHAR(MAX), 
	@seperator VARCHAR(255)
) RETURNS @Values TABLE (NVC1 NVARCHAR(4000) NULL, # BIT NOT NULL, RowNumber INT)
AS
BEGIN
	SET @srcNVC1 = ISNULL(@srcNVC1, '') + @seperator
	DECLARE @NVC1 NVARCHAR(4000), @startNVC1 SMALLINT, @posNVC1 SMALLINT, @count INT
	SELECT @startNVC1 = 1, @posNVC1 = -1,  @count = 0
	WHILE 1 = 1 BEGIN
		IF @posNVC1 > 0 BEGIN
			SET @startNVC1 = @posNVC1 + LEN(@seperator)
		END
		SET @posNVC1 = CHARINDEX(@seperator, @srcNVC1, @startNVC1)
		IF @posNVC1 > 0 BEGIN 
			SET @NVC1 = CAST(NULLIF(SUBSTRING(@srcNVC1, @startNVC1, @posNVC1 - @startNVC1), '') AS NVARCHAR(4000)) 
			SET @count = @count + 1 
		END
		IF @posNVC1 = 0 BREAK
		INSERT @Values (NVC1, #, RowNumber) VALUES (@NVC1, 0, @count)
	END
RETURN
END
