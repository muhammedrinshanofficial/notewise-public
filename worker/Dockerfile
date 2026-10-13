FROM public.ecr.aws/docker/library/alpine:3.20
RUN apk add --no-cache python3 py3-boto3 ffmpeg
COPY validate.py /app/validate.py
CMD ["python3", "-u", "/app/validate.py"]