FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/huggingface \
    TRANSFORMERS_CACHE=/opt/huggingface

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir faster-whisper==1.1.1 huggingface_hub==0.28.1

# Network is needed only while building this image. Runtime can use --network none.
RUN python -c "from huggingface_hub import snapshot_download; snapshot_download('ivrit-ai/whisper-large-v3-turbo-ct2')"

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src

RUN pip install --no-cache-dir --no-deps . \
    && useradd --create-home --uid 10001 safewhisper \
    && mkdir -p /run/safewhisper /tmp \
    && chown -R safewhisper:safewhisper /app /run/safewhisper /tmp /opt/huggingface

USER safewhisper
ENV SAFEWHISPER_SOCKET=/run/safewhisper/engine.sock

ENTRYPOINT ["python", "-m", "safewhisper.engine"]
