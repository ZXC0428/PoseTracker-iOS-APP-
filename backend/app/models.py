import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


class User(Base):
    """遠端登入帳號；PasswordHash 保存 Argon2 雜湊而非明文密碼。"""
    __tablename__ = "Users"

    id: Mapped[uuid.UUID] = mapped_column("Id", Uuid, primary_key=True, default=uuid.uuid4)
    username: Mapped[str] = mapped_column("Username", String(100), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column("PasswordHash", String(500))
    created_at: Mapped[datetime] = mapped_column("CreatedAt", DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column("UpdatedAt", DateTime(timezone=True))

    workouts: Mapped[list["WorkoutRecord"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class WorkoutRecord(Base):
    """一場訓練紀錄；UUID 由 App 產生以支援離線後冪等同步。"""
    __tablename__ = "WorkoutRecords"
    __table_args__ = (
        CheckConstraint("ExerciseType IN ('squat','jumpingJack','lunge')"),
        CheckConstraint("Level IN ('easy','medium','hard')"),
    )

    id: Mapped[uuid.UUID] = mapped_column("Id", Uuid, primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        "UserId", Uuid, ForeignKey("Users.Id", ondelete="CASCADE"), index=True
    )
    exercise_type: Mapped[str] = mapped_column("ExerciseType", String(20))
    level: Mapped[str] = mapped_column("Level", String(20))
    count: Mapped[int] = mapped_column("Count", Integer)
    is_completed: Mapped[bool] = mapped_column("IsCompleted", Boolean)
    workout_timestamp: Mapped[datetime] = mapped_column(
        "WorkoutTimestamp", DateTime(timezone=True)
    )
    created_at: Mapped[datetime] = mapped_column("CreatedAt", DateTime(timezone=True))

    user: Mapped[User] = relationship(back_populates="workouts")


class UserProgress(Base):
    """每位使用者、每種運動目前已解鎖的最高難度。"""
    __tablename__ = "UserProgress"

    user_id: Mapped[uuid.UUID] = mapped_column(
        "UserId", Uuid, ForeignKey("Users.Id", ondelete="CASCADE"), primary_key=True
    )
    exercise_type: Mapped[str] = mapped_column(
        "ExerciseType", String(20), primary_key=True
    )
    highest_unlocked_level: Mapped[str] = mapped_column(
        "HighestUnlockedLevel", String(20)
    )
    updated_at: Mapped[datetime] = mapped_column("UpdatedAt", DateTime(timezone=True))
"""SQL Server 資料表的 SQLAlchemy ORM 對應。"""

