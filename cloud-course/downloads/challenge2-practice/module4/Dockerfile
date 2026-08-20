FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt worker.py ./
RUN pip install --no-cache-dir -r requirements.txt
USER 10001
CMD ["python", "worker.py"]
