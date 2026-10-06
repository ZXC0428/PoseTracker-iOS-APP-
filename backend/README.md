# PoseTracker FastAPI + SQL Server

這個資料夾可複製到 Windows 伺服器 `120.113.70.251` 執行。iPhone 只連
REST API，絕對不要讓 App 直接連 SQL Server。

## 1. Windows 安裝項目

安裝：

1. Python 3.11 或更新版本（安裝時勾選 **Add Python to PATH**）。
2. Microsoft SQL Server（既有 SQL Server 可直接使用）。
3. SQL Server Management Studio (SSMS)。
4. Microsoft ODBC Driver 18 for SQL Server (x64)。

## 2. 建立 Database 與資料表

用 SSMS 連入 SQL Server，以系統管理帳號開啟：

```text
sql/001_create_database_and_tables.sql
```

執行前先把這一段改成真正的強密碼：

```sql
CREATE LOGIN pose_api WITH PASSWORD = 'CHANGE_ME_STRONG_PASSWORD';
```

腳本會建立：

- `PoseTracker` Database
- `Users`
- `WorkoutRecords`
- `UserProgress`
- 權限受限的 SQL Login `pose_api`

`WorkoutRecords.Id` 使用 iPhone 產生的 UUID 作為主鍵，因此同一筆離線紀錄
重送時不會重複建立。

## 3. 建立 Python 環境

在 PowerShell 進入 `backend`：

```powershell
py -3.11 -m venv .venv
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
Copy-Item .env.example .env
```

產生 JWT Secret：

```powershell
python -c "import secrets; print(secrets.token_hex(32))"
```

把結果填入 `.env` 的 `JWT_SECRET`，並將 SQL 密碼填入
`SQLSERVER_CONNECTION_STRING`：

```dotenv
SQLSERVER_CONNECTION_STRING=DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost,1433;DATABASE=PoseTracker;UID=pose_api;PWD=你的SQL密碼;Encrypt=yes;TrustServerCertificate=yes
JWT_SECRET=64字元以上的隨機值
JWT_ALGORITHM=HS256
ACCESS_TOKEN_MINUTES=60
```

開發環境使用自簽憑證時可保留 `TrustServerCertificate=yes`。正式環境應替
SQL Server 設定可信任憑證並改為 `no`。

如果 SQL Server 是 named instance，可將 Server 改成：

```text
SERVER=localhost\SQLEXPRESS
```

## 4. 測試 Python 能否連 SQL Server

```powershell
python test_connection.py
```

成功時會顯示：

```text
SQL Server connection succeeded.
```

常見失敗原因：

- ODBC Driver 18 尚未安裝。
- SQL Server TCP/IP 未啟用。
- SQL Server Authentication 尚未啟用。
- `pose_api` 密碼與 `.env` 不一致。
- 使用的 instance／port 不正確。
- Driver 18 驗證不到 SQL Server 憑證。

## 5. 啟動 REST API

```powershell
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

伺服器本機測試：

```text
http://127.0.0.1:8000/health
http://127.0.0.1:8000/docs
```

Windows 防火牆開放開發用 Port：

```powershell
New-NetFirewallRule -DisplayName "PoseTracker API 8000" `
  -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow
```

外部測試網址：

```text
http://120.113.70.251:8000/health
http://120.113.70.251:8000/docs
```

> `120.113.70.251` 是公開 IP。HTTP 只適合短暫連線測試，不可傳送真實密碼
> 或 Token。正式使用前必須以 Caddy／Nginx／IIS Reverse Proxy 提供 HTTPS
> 443，FastAPI 8000 與 SQL Server 1433 不應直接暴露到 Internet。

## 6. API

| Method | Path | 用途 |
|---|---|---|
| `GET` | `/health` | API 與 SQL Server 健康檢查 |
| `POST` | `/auth/register` | 建立帳號、回傳 JWT |
| `POST` | `/auth/login` | 登入、回傳 JWT |
| `GET` | `/users/me` | 取得登入者 |
| `POST` | `/workouts/sync` | 批次同步離線紀錄 |
| `GET` | `/workouts` | 取得個人訓練歷史 |
| `PUT` | `/progress` | 寫入關卡進度 |
| `GET` | `/progress` | 取得關卡進度 |

除了 `/health`、`/auth/register`、`/auth/login`，其他 API 都要加：

```http
Authorization: Bearer <access_token>
```

## 7. 資安邊界

- SQL Server `1433` 只允許 API 主機本機或內部網路使用。
- `.env` 不可提交 Git，也不可傳給 iPhone。
- 密碼只在 FastAPI 以 Argon2 雜湊後寫入 SQL Server。
- JWT Secret 不可寫死在 Python 或 Swift。
- 正式 API 必須使用 HTTPS。
- 正式上線前還要補 Refresh Token、登出撤銷、限流與刪除帳號。

