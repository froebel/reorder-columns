BEGIN TRAN
--Create some tables.
CREATE TABLE Authors (
	ID INT NOT NULL IDENTITY(1, 1) CONSTRAINT pkcAuthorsID PRIMARY KEY CLUSTERED,
	Name NVARCHAR(127) NOT NULL CONSTRAINT ccAuthorsName CHECK (LEN(Name) != 0)
)

CREATE TABLE Books (
	ID INT NOT NULL IDENTITY(1, 1) CONSTRAINT pkcBooksID PRIMARY KEY CLUSTERED,
	Title NVARCHAR(127) NOT NULL CONSTRAINT ccBooksTitle CHECK (LEN(Title) != 0),
	Pages INT NOT NULL,
	AuthorID INT NOT NULL CONSTRAINT fkcBooksAuthorID FOREIGN KEY REFERENCES Authors(ID) ON DELETE CASCADE
)

CREATE TABLE BooksRented (
	ID INT NOT NULL IDENTITY(1, 1) CONSTRAINT pkcBooksRented PRIMARY KEY CLUSTERED,
	BookID INT NOT NULL CONSTRAINT fkcBooksRented FOREIGN KEY REFERENCES Books(ID),
	Customer NVARCHAR(127) NOT NULL
)

CREATE NONCLUSTERED INDEX niBooksTitle ON Books(Title)
GO
--Create an indexed view that will be recreated as well.
CREATE VIEW vBooksWithAuthors WITH SCHEMABINDING AS
	SELECT Books.ID AS BookID, Books.Title, Books.Pages, Authors.ID AS AuthorID, Authors.Name AS AuthorName
		FROM dbo.Books
		INNER JOIN dbo.Authors ON Authors.Id = Books.AuthorID
GO
CREATE UNIQUE CLUSTERED INDEX ucivBooksWithAuthorsBookID ON vBooksWithAuthors(BookID)
--Insert at least some data.

INSERT Authors (Name) VALUES ('Douglas Adams')
INSERT Books (Title, Pages, AuthorID) VALUES ('The Hitchhiker''s Guide to the Galaxy', 205, 1)
INSERT BooksRented (BookID, Customer) VALUES(1, 'Arthur Dent')

--ResultSet1: Show the new order of columns.
SELECT * FROM Books

--ResultSet2: Output from pReorderColumns to show the changes that are made.
EXEC pReorderColumns @table = 'Books', @newOrder = 'ID, Title, AuthorID, Pages'

--ResultSet3: Show the new order or columns.
SELECT * FROM Books

ROLLBACK TRAN
