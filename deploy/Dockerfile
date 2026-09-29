FROM python:3.13-slim
WORKDIR /app
COPY backend/pyproject.toml ./
COPY backend/telos ./telos
RUN pip install --no-cache-dir .
ENV TELOS_MODEL_PATH=/data/artifacts/mit_model.joblib
EXPOSE 8000
CMD ["uvicorn", "--factory", "telos.server.app:create_app", "--host", "0.0.0.0", "--port", "8000"]
