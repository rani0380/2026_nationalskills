FROM public.ecr.aws/amazonlinux/amazonlinux:2023
WORKDIR /app
COPY stub /app/stub
COPY config.ini /app/config.ini
RUN chmod 755 /app/stub
EXPOSE 8081
ENTRYPOINT ["/app/stub"]
CMD ["--config", "/app/config.ini"]
