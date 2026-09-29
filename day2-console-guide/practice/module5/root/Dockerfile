FROM public.ecr.aws/amazonlinux/amazonlinux:2023
WORKDIR /app
COPY root /app/root
COPY config.ini /app/config.ini
RUN chmod 755 /app/root && mkdir -p /mnt/shgold-efs
EXPOSE 8080
ENTRYPOINT ["/app/root"]
CMD ["--config", "/app/config.ini"]
