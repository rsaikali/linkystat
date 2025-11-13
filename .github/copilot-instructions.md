# LinkyStats - Copilot Agent Instructions

## Project Overview

**LinkyStats** is a real-time electricity consumption monitoring system for French Linky smart meters. The system reads TéléInfo data via USB from the meter, enriches it with weather data from OpenWeather API, stores it in MySQL, and visualizes it through Grafana dashboards.

**Type**: Docker-based Python application (IoT data collection + monitoring)  
**Size**: Small (~500 lines of Python code across 2 modules)  
**Languages**: Python 3.12, Bash, SQL  
**Target Runtime**: Docker containers on self-hosted Raspberry Pi  
**Architecture**: Multi-agent data pipeline with 3 agents (see `agents.md`)

## Critical Build & Run Commands

**IMPORTANT**: All commands must be run from `/app` directory. The project uses Docker Compose with environment files for configuration.

### Environment Setup (REQUIRED FIRST)

```bash
# ALWAYS create .env file before any Docker operations
cp env/.env.sample .env
# Edit .env with proper values for your environment
```

**Critical `.env` variables** (see `env/.env.sample` for full list):
- `LINKY_USB_DEVICE`: USB port for Linky meter (default `/dev/ttyACM0`)
- `OPENWEATHER_API_KEY`, `OPENWEATHER_LATITUDE`, `OPENWEATHER_LONGITUDE`: Weather API credentials
- `MYSQL_*`: Database credentials
- `GF_SECURITY_*`: Grafana admin credentials

**Note**: Grafana is exposed on port 3000. Use an external reverse proxy (Traefik, Caddy, nginx, etc.) to handle HTTPS and domain routing.

### Build & Run

**Development** (in devcontainer):
```bash
# The devcontainer automatically starts services via compose.yaml + compose.dev.yaml
# Container runs `sleep infinity` command, allowing manual Python execution
docker compose --env-file .env ps  # Verify services are running
```

**Production** (on Raspberry Pi):
```bash
# Production deployment with restart policies and USB device mapping
docker compose --env-file .env build --pull
docker compose --env-file .env up -d
```

**Key architectural notes**:
- `compose.yaml`: Base services with production-ready configuration (restart always, USB device, port 3000)
- `compose.dev.yaml`: Development overrides (sleep infinity for manual execution, volume mounts)
- Services: `linky2db` (Python agent), `mysql` (database), `grafana` (visualization on port 3000)

### Code Validation & Linting

**ALWAYS run these before committing**. The CI/CD pipeline expects clean code formatting:

```bash
# Code formatting with black (line-length=256 from pyproject.toml)
black src/

# Verify formatting (exits with code 1 if reformatting needed)
black --check src/

# Import sorting with isort (profile=black from pyproject.toml)
isort src/

# Verify import order (exits with code 1 if sorting needed)
isort --check-only src/

# Flake8 linting (max-line-length=256 from .flake8)
flake8 src/

# Syntax validation
python -m py_compile src/linky2db.py
python -m py_compile src/weather.py
```

**Configuration files**:
- `pyproject.toml`: black (line-length=256, target=py312) + isort settings
- `.flake8`: flake8 config (max-line-length=256, ignore E203,W503,E501,W291,W293)

**Known formatting issues**: The codebase currently has formatting violations. Always run `black src/` and `isort src/` before validation checks.

### Testing

**No test suite exists**. The project has no `pytest.ini`, no test files (`test_*.py`), and pytest is not in `requirements.txt`. To validate changes:

1. **Syntax check**: `python -m py_compile src/<file>.py`
2. **Docker build test**: `docker compose --env-file .env build`
3. **Docker config validation**: `docker compose --env-file .env config` (should output valid YAML)
4. **Manual runtime test**: Run the agent and observe logs for errors

### Common Errors & Workarounds

**Error**: `black --check` fails with "would reformat" message  
**Fix**: Run `black src/` to auto-format code

**Error**: `isort --check-only` fails with "Imports are incorrectly sorted"  
**Fix**: Run `isort src/` to auto-sort imports

**Error**: Docker Compose fails with "no such file or directory: .env"  
**Fix**: Always create `.env` file from `env/.env.sample` before Docker operations

**Error**: MySQL healthcheck fails during startup  
**Fix**: Wait up to 120 seconds for MySQL initialization (healthcheck retries=120, interval=1s)

**Error**: USB device not found (`/dev/ttyACM0`)  
**Fix**: In development, the agent automatically falls back to `LinkyDataFromProd` mode (requires `PRODUCTION_DB_*` variables in `.env`)

## Project Layout & Architecture

### Key Source Files

```
/app/
├── src/
│   ├── linky2db.py          # Main agent: LinkyData + LinkyDataFromProd classes
│   └── weather.py           # TemperatureManager class (OpenWeather API client)
├── pyproject.toml           # black + isort configuration
├── requirements.txt         # Python dependencies (10 packages)
├── Dockerfile               # Python 3.12-slim base image
├── compose.yaml             # Docker Compose services (production-ready)
├── compose.dev.yaml         # Development overrides (sleep infinity)
├── .flake8                  # Flake8 linter config
├── .github/
│   └── workflows/
│       ├── main.yml         # Deploy to production (on push to main)
│       ├── backup.yml       # MySQL backup to Google Drive (daily 3am)
│       └── restore.yml      # MySQL restore from Google Drive (manual)
├── scripts/
│   ├── mysql_backup.sh      # Backup MySQL to .sql.gz
│   ├── mysql_restore.sh     # Restore MySQL from .sql.gz
│   └── sync_dev_db.sh       # Sync production DB to local (SSH-based)
├── files/
│   ├── mysql/init-script.sh # DB schema: linky_realtime + linky_history tables
│   └── grafana/             # Grafana dashboards + datasource configs
└── env/.env.sample          # Template for .env configuration
```

### Agent Architecture (see `agents.md` for details)

**LinkyData** (`src/linky2db.py`): Production agent for real-time USB data collection
- Reads TéléInfo frames from serial port (`LINKY_USB_DEVICE`)
- Validates checksums per TéléInfo specification
- Enriches with temperature via `TemperatureManager`
- Stores in MySQL `linky_realtime` table
- Runs in infinite loop, resilient to DB errors

**LinkyDataFromProd** (`src/linky2db.py`): Development sync agent
- Polls production MySQL for latest data
- Replicates to local development database
- Used when USB device not available (fallback in `__main__`)

**TemperatureManager** (`src/weather.py`): Weather enrichment agent
- Calls OpenWeather API (current weather endpoint)
- TTL cache: 600 seconds (10 minutes)
- Returns temperature in Celsius (rounded to 2 decimals)

### Database Schema (`files/mysql/init-script.sh`)

**Tables**:
- `linky_realtime`: Real-time data (time, PAPP, HCHP, HCHC, temperature, libelle_tarif)
- `linky_history`: Hourly aggregated data

**Triggers**: `realtime_trigger` inserts/updates hourly data in `linky_history`  
**Events**: `clean_realtime` deletes data older than 2 days (runs every minute)

### CI/CD Pipelines

**main.yml** - Deploy to production (on push to main or manual dispatch):
1. Checkout code
2. Create `.env` from GitHub secrets (`ENV_FILE`)
3. Build with `--pull` flag
4. Stop previous containers
5. Start new containers
- Runs on self-hosted runner with label `raspberrypi_rsaikali`

**backup.yml** - MySQL backup (daily 3am or manual):
1. Run `scripts/mysql_backup.sh` (creates `linkystat_mysql_backup.sql.gz`)
2. Upload to Google Drive (both latest + timestamped versions)

**restore.yml** - MySQL restore (manual only):
1. Download latest backup from Google Drive
2. Run `scripts/mysql_restore.sh <backup.sql.gz>`

## Python Dependencies & Versions

**Runtime**: Python 3.12.12 (from `python:3.12-slim` Docker image)  
**Package Manager**: pip (upgraded in Dockerfile)

**Core dependencies** (`requirements.txt`):
- `pyserial==3.5` - USB serial communication
- `requests==2.32.3` - HTTP client for OpenWeather API
- `PyMySQL==1.1.1` - MySQL driver
- `SQLAlchemy==2.0.15` - Database ORM
- `cachetools==5.5.0` - TTL cache for API calls
- `cryptography==43.0.1`, `cffi==1.16.0`, `pycparser==2.21`, `greenlet==3.0.2`, `typing_extensions==4.8.0` - Transitive dependencies

**Development tools** (installed in devcontainer, NOT in requirements.txt):
- `black==25.11.0` - Code formatter
- `flake8==7.3.0` - Linter
- `isort==7.0.0` - Import sorter

**Docker**: 29.0.0  
**Docker Compose**: v2.40.3

## Development Environment

**Devcontainer** (`.devcontainer/devcontainer.json`):
- Base service: `linky2db` from `compose.yaml` + `compose.dev.yaml`
- Command override: `sleep infinity` (allows manual execution)
- Ports forwarded: grafana:3000, mysql:3306
- VSCode extensions: Python, black-formatter, flake8, Pylance, GitLens
- Format on save: Enabled (black + isort)
- Black args: `--line-length=200 --skip-magic-trailing-comma` (NOTE: conflicts with pyproject.toml which sets 256!)

**Development workflow**:
1. Devcontainer auto-starts MySQL and Grafana services
2. Manually run agents: `python src/linky2db.py` or `python src/weather.py`
3. Code auto-formats on save (black + isort)
4. Validate with linters before commit

## Key Files in Repository Root

- `README.md`: Installation guide, hardware requirements, Docker commands
- `LICENSE`: MIT license
- `agents.md`: Detailed agent architecture documentation
- `.gitignore`: Ignores `.env`, `.venv`, `src/__pycache__`, `nohup.out`
- `pyproject.toml`: black + isort configuration (line-length=256)
- `requirements.txt`: Python runtime dependencies
- `.flake8`: Flake8 config (max-line-length=256)
- `Dockerfile`: Python 3.12-slim + pip install requirements
- `compose.yaml`: Production-ready services (linky2db, mysql, grafana with restart policies, USB device, volumes)
- `compose.dev.yaml`: Development overrides (sleep infinity, volume mounts)

## Important Conventions & Patterns

**Code Style**:
- Docstrings: Google-style with Sphinx formatting (`:param`, `:type`, `:return`, `:raises`)
- Language: English for code/comments, French for Grafana variables
- Line length: 256 characters (black + flake8)
- Imports: Auto-sorted with isort (profile=black)
- Logging: `[YYYY-MM-DD HH:MM:SS LEVEL/module] message` format

**Error Handling**:
- Database errors: Log and continue (don't stop data collection)
- Serial errors: Raise (triggers fallback to LinkyDataFromProd)
- API errors: Log warning, set temperature to None

**SQL Queries**:
- Always use parameterized queries via `sa.text()` with `:placeholder` syntax
- Never use string formatting for SQL values

**Configuration**:
- All secrets/config in `.env` file (never hardcode)
- Docker Compose reads `.env` via `--env-file` flag
- Environment variables accessed with `os.getenv()`

## Explicit Validation Steps

Before creating a pull request:

1. **Format code**: `black src/ && isort src/`
2. **Lint code**: `flake8 src/`
3. **Check syntax**: `python -m py_compile src/linky2db.py src/weather.py`
4. **Validate Docker config**: `docker compose --env-file .env config > /dev/null`
5. **Test build**: `docker compose --env-file .env build`
6. **Verify no cached files committed**: `git status` should not show `src/__pycache__/` or `.env`

## Trust These Instructions

These instructions have been validated by running all commands and inspecting actual outputs. Only search for additional information if:
- You encounter an error not documented here
- You need details about a specific function/class implementation
- The user requests something outside the documented structure

When making changes:
1. Always format with black + isort before validation
2. Always test with Docker build (not just syntax check)
3. Always check that `.env` exists before Docker operations
4. Always use parameterized SQL queries
5. Always maintain existing logging format and conventions
