# PoseTracker

PoseTracker 是一套以 iPhone 為核心的姿勢訓練與運動紀錄應用程式。使用者可以登入帳號、選擇訓練項目、透過相機完成訓練，並保存訓練次數與進度；資料也能同步至後端 API，查看排行榜與個人訓練成果。

## 專案功能

### iOS App

- SwiftUI 使用者介面
- 帳號註冊、登入與登出
- 本機使用 SQLite 保存使用者資料、訓練紀錄與進度
- 相機預覽與訓練流程
- 多種訓練項目與關卡解鎖
- 今日訓練次數與歷史紀錄
- 雲端同步訓練紀錄
- 個人進度同步
- 日榜、週榜與月榜
- App icon 與基本 iOS 專案設定

### Backend API

- FastAPI REST API
- SQL Server 資料庫
- JWT Bearer Token 驗證
- Argon2 密碼雜湊
- 使用者註冊與登入
- 訓練紀錄同步與查詢
- 使用者進度更新與查詢
- 依訓練項目與期間計算排行榜
- OpenAPI / Swagger 文件

## 技術架構

| 區域 | 技術 |
| --- | --- |
| iOS | Swift, SwiftUI, URLSession, SQLite3 |
| Backend | Python 3.11+, FastAPI, Uvicorn |
| ORM / Database | SQLAlchemy, Microsoft SQL Server, pyodbc |
| Authentication | JWT, Argon2 |
| API documentation | OpenAPI / Swagger UI |

## 專案結構

```text
.
├── PoseTracker.xcodeproj/       # Xcode 專案
├── PoseTracker/                 # iOS App 原始碼
│   ├── APIClient.swift          # 後端 API 串接
│   ├── AuthenticationView.swift # 登入與註冊畫面
│   ├── ContentView.swift        # 主要訓練流程
│   ├── DatabaseManager.swift    # 本機 SQLite 資料管理
│   ├── LeaderboardView.swift    # 排行榜
│   ├── TrainingSelectionView.swift # 訓練項目選擇
│   └── ...
├── backend/                     # FastAPI 後端
│   ├── app/main.py              # API 路由與應用程式入口
│   ├── app/models.py            # SQLAlchemy models
│   ├── app/schemas.py           # Pydantic schemas
│   ├── app/security.py          # JWT 與密碼驗證
│   ├── sql/                     # SQL Server 建表腳本
│   └── requirements.txt         # Python 相依套件
├── outputs/                     # 專案備份輸出
└── work/                        # 工作素材
```

## API 端點

| Method | Endpoint | 說明 |
| --- | --- | --- |
| GET | `/health` | 檢查 API 與資料庫狀態 |
| POST | `/auth/register` | 建立使用者並取得 Token |
| POST | `/auth/login` | 使用者登入並取得 Token |
| GET | `/users/me` | 取得目前登入使用者 |
| POST | `/workouts/sync` | 同步本機訓練紀錄 |
| GET | `/workouts` | 取得訓練紀錄 |
| PUT | `/progress` | 更新訓練進度 |
| GET | `/progress` | 取得訓練進度 |
| GET | `/leaderboard` | 取得訓練排行榜 |

啟動後可使用以下網址查看 API 文件：

```text
http://127.0.0.1:8000/docs
```

## 啟動 Backend

### 1. 建立 Python 虛擬環境

```powershell
cd backend
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

### 2. 設定環境變數

```powershell
Copy-Item .env.example .env
```

請編輯 `backend/.env`，設定 SQL Server 連線字串與隨機 JWT secret。`.env` 不應提交至 GitHub。

```dotenv
SQLSERVER_CONNECTION_STRING=DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost,1433;DATABASE=PoseTracker;UID=pose_api;PWD=CHANGE_ME;Encrypt=yes;TrustServerCertificate=yes
JWT_SECRET=CHANGE_ME_TO_A_RANDOM_SECRET
JWT_ALGORITHM=HS256
ACCESS_TOKEN_MINUTES=60
```

### 3. 建立資料庫

使用 SQL Server Management Studio 執行：

```text
backend/sql/001_create_database_and_tables.sql
```

### 4. 測試資料庫連線並啟動 API

```powershell
python test_connection.py
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## 啟動 iOS App

1. 使用 macOS 與 Xcode 開啟 `PoseTracker.xcodeproj`。
2. 在 Xcode 選擇 iPhone Simulator 或實體 iPhone。
3. 確認 `PoseTracker/APIClient.swift` 中的 API 位址指向可連線的 Backend。
4. 建置並執行 App。

若使用實體裝置連線到區域網路中的 API，請確認 iPhone 與 API 主機位於同一網路，且防火牆允許 TCP `8000` 連線。正式環境建議使用 HTTPS 與反向代理，不要直接公開開發用 HTTP API。

## 安全注意事項

- 不要提交 `backend/.env`、SQL Server 密碼或 JWT secret。
- 請使用高強度、隨機產生的 JWT secret。
- 正式環境應使用 HTTPS。
- 不要在公開儲存庫中放置真實帳號密碼或私密連線資訊。
- 若 API 位址、資料庫密碼或 Token 曾經公開，請立即更換。

## License

此專案目前未指定開源授權。若要公開授權，請另外新增適合的 `LICENSE` 檔案。
