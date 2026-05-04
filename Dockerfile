FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY reminder.py clients.yaml ./

ENTRYPOINT ["uv", "run", "--no-sync", "python", "reminder.py"]
