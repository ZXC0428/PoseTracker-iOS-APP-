from collections.abc import Generator

from sqlalchemy import URL, create_engine, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import get_settings


class Base(DeclarativeBase):
    """所有 ORM model 共用的 declarative base。"""
    pass


settings = get_settings()

# 直接把完整 ODBC connection string 傳給 pyodbc，避免帳密中的特殊字元
# 被 URL parser 誤解。
connection_url = URL.create(
    "mssql+pyodbc", #連到MS SQL
    query={"odbc_connect": settings.sqlserver_connection_string}, #在.env
)

engine = create_engine(
    connection_url,
    pool_pre_ping=True,
    pool_recycle=1800,
)
# autoflush=False 讓端點明確控制寫入時機；commit 後物件仍可讀取欄位。
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db() -> Generator[Session, None, None]:
    """每個 request 建立獨立 session，結束時自動關閉連線。"""
    with SessionLocal() as session:
        yield session


def check_database_connection() -> None:
    """執行最小查詢，供 /health 與部署診斷確認 SQL Server 可用。"""
    with engine.connect() as connection:  #嘗試連上SQL Server
        connection.execute(text("SELECT 1"))  #測試一個簡單的回應
"""建立 SQLAlchemy engine，並提供 FastAPI request 使用的資料庫 session。"""

