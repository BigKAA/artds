# Dockerfile для ozgurcd/389DS-exporter
# Go-based Prometheus exporter для 389 Directory Server
# Источник: https://github.com/ozgurcd/389DS-exporter

FROM golang:1.21-alpine AS builder

LABEL maintainer="artds-project"
LABEL description="Prometheus exporter for 389 Directory Server (based on ozgurcd/389DS-exporter)"

# Установка зависимостей для сборки
RUN apk add --no-cache git

# Рабочая директория
WORKDIR /build

# Клонирование репозитория ozgurcd/389DS-exporter
RUN git clone https://github.com/ozgurcd/389DS-exporter.git .

# Сборка Go приложения
RUN go build -o 389DS-exporter .

# Финальный образ
FROM alpine:latest

# Установка CA сертификатов для LDAPS
RUN apk --no-cache add ca-certificates

# Создание non-root пользователя
RUN adduser -D -u 1000 exporter

WORKDIR /app

# Копирование скомпилированного бинарника из builder stage
COPY --from=builder /build/389DS-exporter /app/389DS-exporter

# Установка прав
RUN chown exporter:exporter /app/389DS-exporter

# Переключение на non-root пользователя
USER exporter

# Открытие порта для метрик
EXPOSE 9313

# Запуск экспортера
ENTRYPOINT ["/app/389DS-exporter"]

# По умолчанию слушаем на всех интерфейсах
CMD ["--web.listen-address=:9313", "--web.telemetry-path=/metrics"]
