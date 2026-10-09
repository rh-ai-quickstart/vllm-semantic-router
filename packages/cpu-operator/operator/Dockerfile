FROM python:3.12-slim

RUN pip install --no-cache-dir kopf kubernetes pyyaml

COPY operator.py /app/operator.py

USER 1001

ENTRYPOINT ["sh", "-c", "exec kopf run /app/operator.py --namespace ${WATCH_NAMESPACE:-cpu-operator-system}"]
