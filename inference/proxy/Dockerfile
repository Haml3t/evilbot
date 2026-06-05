FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py models.yaml ./

ENV MODELS_FILE=/app/models.yaml
ENV BACKEND_TIMEOUT=300
ENV VRAM_SAFETY_MARGIN_MB=512

EXPOSE 8000

# Run as non-root
RUN useradd -r -s /bin/false proxy
USER proxy

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
