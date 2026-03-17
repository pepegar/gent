FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/ shared/
COPY anthropic/main.py .
EXPOSE 8080
HEALTHCHECK --interval=2s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/__control/health')"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
