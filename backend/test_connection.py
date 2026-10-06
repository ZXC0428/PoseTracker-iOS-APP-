from app.database import check_database_connection


if __name__ == "__main__":
    check_database_connection()
    print("SQL Server connection succeeded.")
"""從命令列快速測試 .env 中的 SQL Server connection string。"""

