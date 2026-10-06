/*
  PoseTracker SQL Server schema
  以有權限建立 Database/Login/User 的系統管理帳號執行。
  請先修改下方 CHANGE_ME 密碼；正式環境使用更長的隨機密碼。
*/

IF DB_ID(N'PoseTracker') IS NULL
BEGIN
    CREATE DATABASE PoseTracker;
END;
GO

USE PoseTracker;
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'pose_api')
BEGIN
    CREATE LOGIN pose_api WITH PASSWORD = 'CHANGE_ME_STRONG_PASSWORD';
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'pose_api')
BEGIN
    CREATE USER pose_api FOR LOGIN pose_api;
END;
GO

IF OBJECT_ID(N'dbo.Users', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Users (
        Id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Users PRIMARY KEY,
        Username NVARCHAR(100) NOT NULL,
        PasswordHash NVARCHAR(500) NOT NULL,
        CreatedAt DATETIMEOFFSET(0) NOT NULL
            CONSTRAINT DF_Users_CreatedAt DEFAULT SYSDATETIMEOFFSET(),
        UpdatedAt DATETIMEOFFSET(0) NOT NULL
            CONSTRAINT DF_Users_UpdatedAt DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT UQ_Users_Username UNIQUE (Username)
    );
END;
GO

IF OBJECT_ID(N'dbo.WorkoutRecords', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WorkoutRecords (
        Id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_WorkoutRecords PRIMARY KEY,
        UserId UNIQUEIDENTIFIER NOT NULL,
        ExerciseType VARCHAR(20) NOT NULL,
        Level VARCHAR(20) NOT NULL,
        [Count] INT NOT NULL,
        IsCompleted BIT NOT NULL,
        WorkoutTimestamp DATETIMEOFFSET(0) NOT NULL,
        CreatedAt DATETIMEOFFSET(0) NOT NULL
            CONSTRAINT DF_WorkoutRecords_CreatedAt DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT FK_WorkoutRecords_Users FOREIGN KEY (UserId)
            REFERENCES dbo.Users(Id) ON DELETE CASCADE,
        CONSTRAINT CK_WorkoutRecords_ExerciseType
            CHECK (ExerciseType IN ('squat', 'jumpingJack', 'lunge')),
        CONSTRAINT CK_WorkoutRecords_Level
            CHECK (Level IN ('easy', 'medium', 'hard')),
        CONSTRAINT CK_WorkoutRecords_Count CHECK ([Count] >= 0)
    );
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_WorkoutRecords_User_Timestamp'
      AND object_id = OBJECT_ID(N'dbo.WorkoutRecords')
)
BEGIN
    CREATE INDEX IX_WorkoutRecords_User_Timestamp
        ON dbo.WorkoutRecords(UserId, WorkoutTimestamp DESC);
END;
GO

IF OBJECT_ID(N'dbo.UserProgress', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserProgress (
        UserId UNIQUEIDENTIFIER NOT NULL,
        ExerciseType VARCHAR(20) NOT NULL,
        HighestUnlockedLevel VARCHAR(20) NOT NULL,
        UpdatedAt DATETIMEOFFSET(0) NOT NULL
            CONSTRAINT DF_UserProgress_UpdatedAt DEFAULT SYSDATETIMEOFFSET(),
        CONSTRAINT PK_UserProgress PRIMARY KEY (UserId, ExerciseType),
        CONSTRAINT FK_UserProgress_Users FOREIGN KEY (UserId)
            REFERENCES dbo.Users(Id) ON DELETE CASCADE,
        CONSTRAINT CK_UserProgress_ExerciseType
            CHECK (ExerciseType IN ('squat', 'jumpingJack', 'lunge')),
        CONSTRAINT CK_UserProgress_Level
            CHECK (HighestUnlockedLevel IN ('easy', 'medium', 'hard'))
    );
END;
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Users TO pose_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.WorkoutRecords TO pose_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.UserProgress TO pose_api;
GO

