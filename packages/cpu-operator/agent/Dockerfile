FROM python:3.12-slim

RUN pip install --no-cache-dir kubernetes

COPY agent.py /app/agent.py

USER 1001

ENTRYPOINT ["python", "/app/agent.py"]
