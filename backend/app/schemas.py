import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

ExerciseType = Literal["squat", "jumpingJack", "lunge"]
Level = Literal["easy", "medium", "hard"]
LeaderboardPeriod = Literal["daily", "weekly"]


class RegisterRequest(BaseModel):
    """註冊欄位與最基本的長度限制。"""
    username: str = Field(min_length=3, max_length=100)
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(RegisterRequest):
    """登入與註冊目前使用相同帳密格式。"""
    pass


class TokenResponse(BaseModel):
    """登入成功後供 App 保存的 Bearer token 與使用者識別。"""
    access_token: str
    token_type: str = "bearer"
    user_id: uuid.UUID
    username: str


class DUserResponse(BaseModel):
    """不暴露 password_hash 的公開使用者資料。"""
    id: uuid.UUID
    username: str
    model_config = ConfigDict(from_attributes=True)


class WorkoutInput(BaseModel):
    """App 上傳的一筆離線訓練紀錄。"""
    id: uuid.UUID
    exercise_type: ExerciseType
    level: Level
    count: int = Field(ge=0)
    is_completed: bool
    timestamp: datetime


class WorkoutSyncRequest(BaseModel):
    """單次最多同步 500 筆，避免 request 過大。"""
    records: list[WorkoutInput] = Field(max_length=500)


class WorkoutSyncResponse(BaseModel):
    """確認 backend 已接受哪些 UUID。"""
    synced_ids: list[uuid.UUID]


class WorkoutResponse(WorkoutInput):
    """歷史紀錄回傳格式與上傳格式相同。"""
    pass


class ProgressInput(BaseModel):
    """單項運動的最高解鎖關卡。"""
    exercise_type: ExerciseType
    highest_unlocked_level: Level


class ProgressResponse(ProgressInput):
    """解鎖進度與最後更新時間。"""
    updated_at: datetime
    model_config = ConfigDict(from_attributes=True)


class LeaderboardBreakdown(BaseModel):
    """排行榜中單一難度的次數、場次、每日獎勵與小計。"""
    level: Level
    count: int
    completed_workouts: int
    completion_bonus: float
    score: float


class LeaderboardEntry(BaseModel):
    """單一使用者的排行榜總覽及可解釋的分數明細。"""
    rank: int
    username: str
    total_count: int
    completed_workouts: int
    score: float
    all_levels_bonus: float
    breakdown: list[LeaderboardBreakdown]
"""FastAPI request/response 的 Pydantic 驗證模型。"""
