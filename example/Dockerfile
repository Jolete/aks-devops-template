FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && mkdir /data && chown 10001:10001 /data
ENV DB_PATH=/data/example.sqlite3 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
COPY *.py ./
USER 10001:10001
EXPOSE 8080
CMD ["python", "api.py"]
