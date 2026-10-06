from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """集中定義所有可由環境變數覆蓋的 backend 設定。"""
    sqlserver_connection_string: str
    jwt_secret: str
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 60

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


@lru_cache
def get_settings() -> Settings:
    """每個 process 只解析一次 .env，避免每次 request 重讀檔案。"""
    return Settings()
"""從 .env 載入 SQL Server 與 JWT 設定。"""

