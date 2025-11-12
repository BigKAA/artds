#!/bin/bash
# enable-json-logging.sh
# Скрипт для включения JSON логирования в 389ds

set -e

# Переменные
DS_DM_PASSWORD="${DS_DM_PASSWORD:-password}"
DS_INSTANCE="${DS_INSTANCE:-localhost}"
ENABLE_JSON="${ENABLE_JSON_LOGGING:-true}"

if [ "$ENABLE_JSON" != "true" ]; then
    echo "JSON logging disabled via ENABLE_JSON_LOGGING=false"
    exit 0
fi

echo "🔧 Включение JSON логирования для 389ds..."

# Access Log JSON
echo "  Настройка Access Log..."
dsconf $DS_INSTANCE logging access set log-format json
dsconf $DS_INSTANCE logging access set time-format "%Y-%m-%dT%H:%M:%S%z"

# Error Log JSON
echo "  Настройка Error Log..."
dsconf $DS_INSTANCE logging error set log-format json
dsconf $DS_INSTANCE logging error set time-format "%Y-%m-%dT%H:%M:%S%z"

# Audit Log JSON (если поддерживается версией)
echo "  Настройка Audit Log (если доступен)..."
dsconf $DS_INSTANCE logging audit set log-format json 2>/dev/null || \
    echo "  ⚠️ Audit JSON не поддерживается этой версией 389ds"

echo "✅ JSON логирование успешно настроено"
echo ""
echo "Примеры просмотра логов:"
echo "  docker logs ds389-1 | jq ."
echo "  docker logs ds389-1 | jq 'select(.operation==\"BIND\")'"
