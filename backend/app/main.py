import uuid
from datetime import datetime, time, timedelta, timezone
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .database import check_database_connection, get_db
from .models import User, UserProgress, WorkoutRecord
from .schemas import (
    LoginRequest,
    LeaderboardBreakdown,
    LeaderboardEntry,
    ProgressInput,
    ProgressResponse,
    RegisterRequest,
    TokenResponse,
    UserResponse,
    WorkoutResponse,
    WorkoutSyncRequest,
    WorkoutSyncResponse,
)
from .security import create_access_token, get_current_user, hash_password, verify_password

app = FastAPI(title="PoseTracker API", version="0.1.0")
# 台灣目前固定 UTC+8；使用固定 offset 可避免 Windows 缺少 IANA tzdata。
TAIPEI = timezone(timedelta(hours=8), name="Asia/Taipei")


@app.get("/health")
def health() -> dict[str, str]:
    """同時確認 HTTP service 與 SQL Server 連線是否正常。"""
    check_database_connection()
    return {"status": "ok"}


@app.post("/auth/register", response_model=TokenResponse, status_code=201)
def register(payload: RegisterRequest, db: Annotated[Session, Depends(get_db)]):
    """建立帳號、雜湊密碼，並直接回傳登入 token。"""
    # 帳號統一去除頭尾空白並轉小寫，避免大小寫造成重複帳號。
    username = payload.username.strip().lower()
    if db.scalar(select(User).where(User.username == username)):
        raise HTTPException(status_code=409, detail="Username already exists")
    now = datetime.now(timezone.utc)
    user = User(
        id=uuid.uuid4(),
        username=username,
        password_hash=hash_password(payload.password),
        created_at=now,
        updated_at=now,
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        # 仍保留 DB unique constraint 防止同時註冊造成 race condition。
        db.rollback()
        raise HTTPException(status_code=409, detail="Username already exists")
    db.refresh(user)
    return TokenResponse(
        access_token=create_access_token(user),
        user_id=user.id,
        username=user.username,
    )


@app.post("/auth/login", response_model=TokenResponse)
def login(payload: LoginRequest, db: Annotated[Session, Depends(get_db)]):
    """驗證帳密；失敗時不透露究竟是帳號或密碼錯誤。"""
    username = payload.username.strip().lower()
    user = db.scalar(select(User).where(User.username == username))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
        )
    return TokenResponse(
        access_token=create_access_token(user),
        user_id=user.id,
        username=user.username,
    )


@app.get("/users/me", response_model=UserResponse)
def me(current_user: Annotated[User, Depends(get_current_user)]):
    """以 token 取得目前登入者的公開資料。"""
    return current_user


@app.post("/workouts/sync", response_model=WorkoutSyncResponse)
def sync_workouts(
    payload: WorkoutSyncRequest,
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    """批次保存離線紀錄；相同 UUID 重送不會建立重複資料。"""
    synced: list[uuid.UUID] = []
    for item in payload.records:
        existing = db.get(WorkoutRecord, item.id)
        if existing is not None:
            # UUID 已存在但屬於他人時拒絕，避免跨帳號覆寫資料。
            if existing.user_id != current_user.id:
                raise HTTPException(status_code=409, detail=f"Record ID conflict: {item.id}")
            synced.append(item.id)
            continue
        db.add(WorkoutRecord(
            id=item.id,
            user_id=current_user.id,
            exercise_type=item.exercise_type,
            level=item.level,
            count=item.count,
            is_completed=item.is_completed,
            workout_timestamp=item.timestamp,
            created_at=datetime.now(timezone.utc),
        ))
        synced.append(item.id)
    db.commit()
    return WorkoutSyncResponse(synced_ids=synced)


@app.get("/workouts", response_model=list[WorkoutResponse])
def list_workouts(
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    """依時間由新到舊回傳目前登入者的完整訓練歷史。"""
    records = db.scalars(
        select(WorkoutRecord)
        .where(WorkoutRecord.user_id == current_user.id)
        .order_by(WorkoutRecord.workout_timestamp.desc())
    ).all()
    return [WorkoutResponse(
        id=row.id,
        exercise_type=row.exercise_type,
        level=row.level,
        count=row.count,
        is_completed=row.is_completed,
        timestamp=row.workout_timestamp,
    ) for row in records]


@app.put("/progress", response_model=ProgressResponse)
def update_progress(
    payload: ProgressInput,
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    """新增或更新某運動的最高解鎖難度。"""
    key = {"user_id": current_user.id, "exercise_type": payload.exercise_type}
    progress = db.get(UserProgress, key)
    now = datetime.now(timezone.utc)
    if progress is None:
        progress = UserProgress(
            **key,
            highest_unlocked_level=payload.highest_unlocked_level,
            updated_at=now,
        )
        db.add(progress)
    else:
        progress.highest_unlocked_level = payload.highest_unlocked_level
        progress.updated_at = now
    db.commit()
    db.refresh(progress)
    return progress


@app.get("/progress", response_model=list[ProgressResponse])
def list_progress(
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    """下載目前登入者三種運動的解鎖進度。"""
    return db.scalars(
        select(UserProgress).where(UserProgress.user_id == current_user.id)
    ).all()


@app.get("/leaderboard", response_model=list[LeaderboardEntry])
def leaderboard(
    period: Annotated[Literal["daily", "weekly"], Query()],
    exercise_type: Annotated[
        Literal["squat", "jumpingJack", "lunge"], Query()
    ],
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    """計算今日或本週排行榜，包含每日過關與三關全過獎勵。"""
    del current_user  # 排行榜須登入才能查看，但統計包含所有使用者。
    now = datetime.now(TAIPEI)
    today_start = datetime.combine(now.date(), time.min, tzinfo=TAIPEI)
    # 週榜固定從星期一 00:00 起算，再轉 UTC 與 DATETIMEOFFSET 比較。
    if period == "daily":
        start = today_start
    else:
        start = today_start - timedelta(days=today_start.weekday())
    start_utc = start.astimezone(timezone.utc)

    # 只取已過關紀錄；未完成訓練仍保留在歷史，但不參與排行榜。
    rows = db.execute(
        select(
            User.username,
            WorkoutRecord.level,
            WorkoutRecord.count,
            WorkoutRecord.workout_timestamp,
        )
        .join(User, User.id == WorkoutRecord.user_id)
        .where(
            WorkoutRecord.exercise_type == exercise_type,
            WorkoutRecord.is_completed == True,  # noqa: E712 - SQL Server BIT 必須產生 = 1
            WorkoutRecord.workout_timestamp >= start_utc,
        )
    ).all()

    weights = {"easy": 1.0, "medium": 1.5, "hard": 2.0}
    daily_bonuses = {"easy": 5.0, "medium": 10.0, "hard": 20.0}
    # 先按使用者累加原始次數、完成場次及各難度曾過關的台灣日期。
    stats: dict[str, dict] = {}
    for row in rows:
        user_stats = stats.setdefault(row.username, {
            "total_count": 0,
            "completed_workouts": 0,
            "counts": {level: 0 for level in weights},
            "workouts": {level: 0 for level in weights},
            "days": {level: set() for level in weights},
        })
        timestamp = row.workout_timestamp
        # 某些 pyodbc/SQL Server 組合可能回傳 naive datetime；資料庫一律視為 UTC。
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=timezone.utc)
        workout_day = timestamp.astimezone(TAIPEI).date()
        user_stats["total_count"] += int(row.count)
        user_stats["completed_workouts"] += 1
        user_stats["counts"][row.level] += int(row.count)
        user_stats["workouts"][row.level] += 1
        user_stats["days"][row.level].add(workout_day)

    ranked: list[LeaderboardEntry] = []
    for username, user_stats in stats.items():
        # 每個難度每天只領一次首次過關獎勵，重複完成仍計次數分。
        level_bonuses = {
            level: len(user_stats["days"][level]) * daily_bonuses[level]
            for level in weights
        }
        all_level_days = set.intersection(
            *(user_stats["days"][level] for level in weights)
        )
        # 三個日期集合的交集，代表同一天三種難度都已過關。
        all_levels_bonus = len(all_level_days) * 15.0
        base_score = sum(
            user_stats["counts"][level] * weights[level]
            for level in weights
        )
        total_score = base_score + sum(level_bonuses.values()) + all_levels_bonus
        ranked.append(LeaderboardEntry(
            rank=0,
            username=username,
            total_count=user_stats["total_count"],
            completed_workouts=user_stats["completed_workouts"],
            score=total_score,
            all_levels_bonus=all_levels_bonus,
            breakdown=[
                LeaderboardBreakdown(
                    level=level,
                    count=user_stats["counts"][level],
                    completed_workouts=user_stats["workouts"][level],
                    completion_bonus=level_bonuses[level],
                    score=(user_stats["counts"][level] * weights[level]
                           + level_bonuses[level]),
                ) for level in weights
            ],
        ))

    # 先比分數；同分時以實際完成總次數較多者優先。
    ranked.sort(key=lambda entry: (entry.score, entry.total_count), reverse=True)
    return [entry.model_copy(update={"rank": index})
            for index, entry in enumerate(ranked[:100], start=1)]
"""PoseTracker REST API：帳號、訓練同步、解鎖進度與排行榜。"""
