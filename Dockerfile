FROM alpine:latest

RUN mkdir -p /app

COPY zig-out/bin/rinha-de-backend /app

COPY data.db /app

WORKDIR /app

EXPOSE 3000
EXPOSE 9999

CMD ["/app/rinha-de-backend"]