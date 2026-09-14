FROM python:3.12-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install
COPY agent/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy agent source code
COPY agent/ ./agent/
COPY rag/ ./rag/
COPY docs/runbooks/ ./docs/runbooks/
COPY vector-db/ ./vector-db/

# Set working directory for imports
WORKDIR /app

# Start agent
CMD ["uvicorn", "agent.main:app", "--host", "0.0.0.0", "--port", "8001"]