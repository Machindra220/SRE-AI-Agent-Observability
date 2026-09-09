FROM python:3.12-slim

WORKDIR /app

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser 

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt 

COPY src/ ./src/

USER appuser

EXPOSE 8080

CMD ["ddtrace-run", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]