# `make docker-up` Quick Reference

## What It Does

Starts the complete EdgeQuake full stack via Docker Compose:

- PostgreSQL database (port 5432)
- Backend API (port 8080)
- Frontend web UI (port 3000)

## Quick Start

```bash
make docker-up
```

## Expected Output

The command will display something like:

```
🐳 Starting EdgeQuake Full Stack via Docker

→ Building and starting services...

→ Waiting for services to be ready...

✅ EdgeQuake Docker Stack is Running

📍 Access Points:

  Frontend (Web UI)
    🌐 URL: http://localhost:3000
    📝 Navigate here to upload documents and interact with the knowledge graph

  Backend API
    🔗 URL: http://localhost:8080
    📚 Swagger UI: http://localhost:8080/swagger-ui
    🏥 Health: http://localhost:8080/health

  Database
    🗄️  PostgreSQL on port 5432
    👤 User: edgequake

→ First Time:
  1. Open http://localhost:3000 in your browser
  2. Upload a PDF document from the File menu
  3. Wait for entity extraction to complete
  4. View the knowledge graph and extracted entities

→ Management:
  See logs: make docker-logs
  Stop stack: make docker-down
  Check status: make docker-ps
```

## URLs to Access

| Service           | URL                              | Purpose                                |
| ----------------- | -------------------------------- | -------------------------------------- |
| Frontend          | http://localhost:3000            | Web UI for documents & knowledge graph |
| Backend API       | http://localhost:8080            | REST API endpoints                     |
| API Documentation | http://localhost:8080/swagger-ui | Interactive API explorer               |
| Health Check      | http://localhost:8080/health     | Service status                         |

## Timeline

| Step | Time      | What Happens                                                  |
| ---- | --------- | ------------------------------------------------------------- |
| 1    | Immediate | Building Docker images (first time ~5-15 min, cached ~30 sec) |
| 2    | ~30 sec   | PostgreSQL initializes                                        |
| 3    | ~20 sec   | Backend API starts and connects to database                   |
| 4    | ~30 sec   | Frontend starts and connects to backend                       |
| 5    | Ready     | All services healthy and accessible                           |

## Common Commands

```bash
# View all services
make docker-ps

# Follow all logs
make docker-logs

# Stop everything
make docker-down

# Rebuild images
make docker-build

# Clean everything
docker compose -f edgequake/docker/docker-compose.yml down -v
```

## System Requirements

- **Docker**: Must be running
- **Port 3000**: Must be available (or set FRONTEND_PORT)
- **Port 8080**: Must be available (or set EDGEQUAKE_PORT)
- **Port 5432**: Must be available (or set POSTGRES_PORT)
- **RAM**: 4GB minimum, 8GB recommended
- **Disk**: 10GB minimum for images

## First Time Setup

1. **Start the stack**

   ```bash
   make docker-up
   ```

2. **Wait for "Docker Stack is Running" message** (~1-2 minutes)

3. **Open http://localhost:3000 in your browser**

4. **Upload a test PDF** (you can use any PDF from `zz_test_docs/` folder)

5. **Wait for processing** (status will change from "Processing" to "Completed")

6. **View results** - Click the document to see extracted content and knowledge graph

## Troubleshooting

### "Port already in use"

```bash
# Find what's using the port
lsof -i :3000
lsof -i :8080
lsof -i :5432

# Kill it
kill -9 <PID>
```

### Services not starting

```bash
# Check logs
docker logs edgequake
docker logs edgequake-frontend
docker logs edgequake-postgres

# Restart
make docker-down
make docker-up
```

### Get better error messages

```bash
# Run without background
docker compose -f edgequake/docker/docker-compose.yml up
```

## Environment Variables

Override default configuration:

```bash
# Custom ports
EDGEQUAKE_PORT=9000 FRONTEND_PORT=4000 make docker-up

# With OpenAI
OPENAI_API_KEY="sk-..." make docker-up

# Database password
POSTGRES_PASSWORD="mypassword" make docker-up
```

## Documentation

- **Full Guide**: See `DOCKER_DEPLOYMENT.md`
- **Implementation Details**: See `DOCKER_SETUP_IMPLEMENTATION.md`
- **Verify Setup**: Run `scripts/verify-docker-setup.sh`

## Architecture

```
┌──────────────────────────────────────────┐
│         Docker Host Machine              │
│  (Your computer running Docker)          │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │   edgequake-network (bridge)     │   │
│  │                                  │   │
│  │  ┌────────────┐   ┌──────────┐   │   │
│  │  │ PostgreSQL │   │ Backend  │   │   │
│  │  │  :5432     │   │  :8080   │   │   │
│  │  └────────────┘   └──────────┘   │   │
│  │       ▲                 ▲        │   │
│  │       │                 │        │   │
│  │       └─────────┬───────┘        │   │
│  │                 │                │   │
│  │       ┌─────────▼────────┐       │   │
│  │       │   Frontend       │       │   │
│  │       │     :3000        │       │   │
│  │       └──────────────────┘       │   │
│  │                                  │   │
│  └──────────────────────────────────┘   │
│                                         │
│    Exposed on Host:                     │
│    - http://localhost:3000 (Frontend)   │
│    - http://localhost:8080 (Backend)    │
│    - localhost:5432 (Database)          │
└─────────────────────────────────────────┘
```

## Support

If you encounter any issues:

1. Check the troubleshooting section above
2. Read `DOCKER_DEPLOYMENT.md` for detailed explanations
3. Run `scripts/verify-docker-setup.sh` to validate setup
4. Check Docker logs with `make docker-logs`
