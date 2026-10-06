import uuid
from datetime import datetime, timedelta, timezone
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt.exceptions import InvalidTokenError
from pwdlib import PasswordHash
from sqlalchemy.orm import Session

from .config import get_settings
from .database import get_db
from .models import User

# pwdlib.recommended() 目前使用安全的現代雜湊設定（例如 Argon2）。
password_hasher = PasswordHash.recommended()
# HTTPBearer 會從 Authorization: Bearer <token> 取出 credentials。
bearer_scheme = HTTPBearer()


def hash_password(password: str) -> str:
    """註冊時將明文密碼轉成不可逆雜湊。"""
    return password_hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    """登入時以雜湊函式安全比對密碼。"""
    return password_hasher.verify(password, password_hash)


def create_access_token(user: User) -> str:
    """建立有到期時間的 JWT；sub 固定放使用者 UUID。"""
    settings = get_settings()
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user.id),
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials, Depends(bearer_scheme)],
    db: Annotated[Session, Depends(get_db)],
) -> User:
    """驗證 JWT 並載入使用者，供受保護端點作為 FastAPI dependency。"""
    settings = get_settings()
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired access token",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        token = credentials.credentials
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
        user_id = uuid.UUID(payload["sub"])
    except (InvalidTokenError, KeyError, ValueError):
        raise credentials_error
    user = db.get(User, user_id)
    if user is None:
        raise credentials_error
    return user
"""密碼雜湊、JWT 建立與 Bearer token 驗證。"""
