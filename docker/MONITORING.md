# Мониторинг 389 Directory Server с Prometheus и Grafana

Это руководство объясняет, как развернуть полный стек мониторинга для 389 Directory Server, используя Prometheus, пользовательские exporters и дашборды Grafana.

## Архитектура

```
┌─────────────────────────────────────────────────────────┐
│                   Monitoring Stack                       │
│                                                          │
│  ┌─────────┐    ┌──────────┐    ┌────────────┐        │
│  │   ds1   │───▶│ds1-export│───▶│            │         │
│  │  :3389  │    │  :9313   │    │ Prometheus │◀───┐    │
│  └─────────┘    └──────────┘    │   :9090    │    │    │
│                                  └─────┬──────┘    │    │
│  ┌─────────┐    ┌──────────┐          │           │    │
│  │   ds2   │───▶│ds2-export│──────────┘           │    │
│  │  :4389  │    │  :9314   │                      │    │
│  └─────────┘    └──────────┘                      │    │
│                                                    │    │
│                                             ┌──────▼────▼──┐
│                                             │   Grafana    │
│                                             │    :3000     │
│                                             └──────────────┘
└─────────────────────────────────────────────────────────┘
```

## Компоненты

### 389 Directory Server (ds1, ds2)
- **Назначение**: LDAP серверы, предоставляющие службы каталогов
- **Порты**: 3389/4389 (LDAP), 3636/4636 (LDAPS)
- **Мониторинг**: Предоставление статистики через LDAP дерево cn=monitor
- **JSON логирование**: Включено для структурированного анализа логов

### Prometheus Exporters (ds1-exporter, ds2-exporter)
- **Назначение**: Запрос cn=monitor и предоставление метрик для Prometheus
- **Порт**: 9313/9314
- **Собираемые метрики**:
  - Текущие/общие подключения
  - Операции по типам (search, bind, add, delete, modify)
  - Количество записей в backend
  - Коэффициенты попаданий в кэш (entry cache, DN cache)
  - Информация о версии сервера

### Prometheus Server
- **Назначение**: База данных временных рядов для хранения метрик
- **Порт**: 9090
- **Функции**:
  - Период хранения 30 дней
  - Интервал сбора 30 секунд
  - Веб UI для PromQL запросов
  - Включено управление жизненным циклом

### Grafana
- **Назначение**: Визуализация и дашборды
- **Порт**: 3000
- **Учетные данные по умолчанию**: admin/admin (измените при первом входе)
- **Функции**:
  - Автоматически настроенный источник данных Prometheus
  - Предварительно настроенный дашборд обзора 389ds
  - Поддержка пользовательских дашбордов

---

## Быстрый старт

### Предварительные требования
- Установлены Docker и Docker Compose
- Минимум 4GB доступной RAM
- Доступны порты 3000, 3389-4389, 3636-4636, 9090, 9313-9314

### 1. Клонирование репозитория
```bash
git clone <repository-url>
cd artds/docker
```

### 2. Настройка паролей
Отредактируйте [docker-compose-monitoring.yml](docker-compose-monitoring.yml) и обновите пароли:
```yaml
DS_DM_PASSWORD=YourStrongAdminPassword  # Измените это!
BIND_PASSWORD=YourStrongAdminPassword   # Совпадает с вышеуказанным
```

Также обновите в:
- `monitoring/config-ds1.yaml`
- `monitoring/config-ds2.yaml`

### 3. Сборка образа Exporter
```bash
cd ../monitoring/389ds-exporter
./build.sh
cd ../../docker
```

### 4. Запуск стека мониторинга
```bash
docker-compose -f docker-compose-monitoring.yml up -d
```

### 5. Проверка сервисов
```bash
# Проверить, что все сервисы запущены
docker-compose -f docker-compose-monitoring.yml ps

# Проверить здоровье ds1
docker exec ds1 dsctl localhost status

# Проверить здоровье ds2
docker exec ds2 dsctl localhost status

# Проверить метрики exporter
curl http://localhost:9313/metrics
curl http://localhost:9314/metrics
```

### 6. Доступ к дашбордам
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (admin/admin)

---

## Ключевые метрики

### Метрики подключений
| Метрика | Описание | Тип |
|--------|-------------|------|
| `ldap_connections_current` | Текущие активные LDAP подключения | Gauge |
| `ldap_connections_total` | Общее количество подключений с момента запуска | Counter |

**Примеры PromQL**:
```promql
# Текущие подключения на сервер
ldap_connections_current{server=~"ds.*"}

# Скорость подключений (в секунду)
rate(ldap_connections_total[5m])
```

### Метрики операций
| Метрика | Описание | Тип |
|--------|-------------|------|
| `ldap_operations_total` | Общее количество операций по типам | Counter |

**Labels**: `server`, `operation` (search, bind, add, delete, modify, compare, moddn)

**Примеры PromQL**:
```promql
# Операции поиска в секунду
rate(ldap_operations_total{operation="search"}[5m])

# Топ операций по типу
topk(5, sum by (operation) (rate(ldap_operations_total[5m])))
```

### Метрики Backend
| Метрика | Описание | Тип |
|--------|-------------|------|
| `ldap_entries_total` | Общее количество LDAP записей в backend | Gauge |
| `ldap_backend_entry_cache_hits` | Попадания в кэш записей | Counter |
| `ldap_backend_entry_cache_tries` | Попытки обращения к кэшу записей | Counter |
| `ldap_backend_dn_cache_hits` | Попадания в DN кэш | Counter |
| `ldap_backend_dn_cache_tries` | Попытки обращения к DN кэшу | Counter |

**Примеры PromQL**:
```promql
# Коэффициент попаданий в кэш записей
rate(ldap_backend_entry_cache_hits[5m]) /
rate(ldap_backend_entry_cache_tries[5m])

# Коэффициент попаданий в DN кэш
rate(ldap_backend_dn_cache_hits[5m]) /
rate(ldap_backend_dn_cache_tries[5m])
```

### Информация о сервере
| Метрика | Описание | Тип |
|--------|-------------|------|
| `ldap_server_info` | Версия сервера и метаданные | Info |

---

## Дашборд Grafana

### Предварительно настроенный дашборд: "389 Directory Server - Overview"

**Панели**:
1. **Current LDAP Connections** - Индикатор показывающий активные подключения
2. **LDAP Operations Rate** - Временной ряд операций в секунду по типам
3. **Cache Hit Ratio** - Временной ряд эффективности кэша записей и DN
4. **Total LDAP Entries** - Индикатор показывающий количество записей на backend

### Создание пользовательских дашбордов

1. Войдите в Grafana: http://localhost:3000
2. Перейдите в **Dashboards** → **New** → **New Dashboard**
3. Добавьте панель с источником данных Prometheus
4. Используйте PromQL запросы из раздела "Ключевые метрики" выше
5. Сохраните дашборд в папку **389 Directory Server**

**Пример панели - Задержка поиска**:
```promql
histogram_quantile(0.95,
  sum(rate(ldap_operation_duration_seconds_bucket{operation="search"}[5m]))
  by (le, server)
)
```

---

## Решение проблем

### Exporter не может подключиться к LDAP серверу

**Симптомы**:
- Нет метрик по адресу http://localhost:9313/metrics
- Логи exporter показывают ошибки подключения

**Решение**:
```bash
# Проверить логи exporter
docker logs ds1-exporter

# Убедиться, что LDAP сервер доступен
docker exec ds1-exporter nc -zv ds1 3389

# Протестировать LDAP bind
docker exec ds1-exporter ldapsearch -x -H ldap://ds1:3389 \
  -D "cn=Directory Manager" -w YourStrongAdminPassword \
  -b "cn=monitor" -s base "(objectClass=*)"
```

### Prometheus не собирает метрики с целей

**Симптомы**:
- Цели показывают "DOWN" в UI Prometheus (http://localhost:9090/targets)

**Решение**:
```bash
# Проверить логи Prometheus
docker logs prometheus

# Убедиться, что exporter отвечает
curl http://ds1-exporter:9313/metrics

# Проверить сетевое подключение
docker exec prometheus nc -zv ds1-exporter 9313
```

### Grafana не показывает данные

**Симптомы**:
- Дашборды загружаются, но панели показывают "No data"

**Решение**:
```bash
# Проверить источник данных Grafana
# Перейти в Configuration → Data Sources → Prometheus
# Нажать кнопку "Test" - должно показать зеленый "Data source is working"

# Убедиться, что Prometheus имеет данные
# Перейти на http://localhost:9090/graph
# Выполнить запрос: ldap_connections_current
# Должно показать результаты

# Проверить временной диапазон в дашборде Grafana (вверху справа)
```

### Метрики кэша показывают ноль

**Симптомы**:
- Панели коэффициента попаданий в кэш не показывают данные или 0%

**Решение**:
Мониторинг backend требует правильной настройки плагина ldbm database. Проверьте:
```bash
# Убедиться, что backend существует
docker exec ds1 dsconf localhost backend suffix list

# Проверить дерево monitor
docker exec ds1 ldapsearch -x -H ldap://localhost:3389 \
  -D "cn=Directory Manager" -w YourStrongAdminPassword \
  -b "cn=ldbm database,cn=plugins,cn=config,cn=monitor" \
  -s one "(objectClass=*)"
```

### JSON логи не отформатированы

**Симптомы**:
- Логи в `/var/log/dirsrv/slapd-localhost/` не в JSON формате

**Решение**:
```bash
# Проверить, запустился ли скрипт JSON логирования
docker logs ds1 | grep "JSON logging"

# Включить JSON логирование вручную
docker exec ds1 dsconf localhost logging access set log-format json
docker exec ds1 dsconf localhost logging error set log-format json
```

---

## Соображения для production

### Безопасность

1. **Изменить пароли по умолчанию**
   - Обновить `DS_DM_PASSWORD` в docker-compose.yml
   - Изменить пароль администратора Grafana при первом входе
   - Хранить пароли в Docker secrets для Swarm развертываний

2. **Безопасность сети**
   - Использовать внутренние Docker сети для коммуникации компонентов
   - Предоставлять доступ только к необходимым портам хоста
   - Рассмотреть использование TLS/LDAPS (порт 3636) для LDAP подключений

3. **Аутентификация**
   - Настроить OAuth/LDAP аутентификацию в Grafana
   - Настроить basic auth в Prometheus для удаленного доступа
   - Ограничить доступ к эндпоинтам метрик

### Производительность

1. **Лимиты ресурсов**
   - Установить лимиты памяти/CPU в docker-compose.yml
   - Мониторить использование ресурсов контейнера: `docker stats`

2. **Хранилище**
   - Настроить хранение в Prometheus в зависимости от потребностей
   - Настроить резервные копии volumes для постоянных данных
   - Мониторить использование диска: `docker system df`

3. **Интервалы сбора**
   - Балансировать между детализацией данных и накладными расходами
   - Значение по умолчанию 30s подходит для большинства развертываний
   - Увеличить для высоконагруженных окружений

### Высокая доступность

Для production HA установки рассмотрите:
- Множественные экземпляры Prometheus с удаленным хранилищем (Thanos, Cortex)
- Режим HA для Grafana с общей базой данных
- Load balancer для экземпляров Grafana
- Федерацию Prometheus для мультикластерного мониторинга

См. [Руководства по развертыванию Kubernetes/Helm](../kubernetes/README.md) для HA архитектур.

---

## Масштабирование

### Добавление дополнительных экземпляров 389ds

1. Добавить новый сервис в docker-compose-monitoring.yml:
```yaml
  ds3:
    image: 389ds/dirsrv:latest
    hostname: ds3
    ports:
      - "5389:3389"
    # ... аналогичная конфигурация ds1/ds2

  ds3-exporter:
    build: ../monitoring/389ds-exporter
    environment:
      - LDAP_URI=ldap://ds3:3389
      - SERVER_NAME=ds3
    # ... аналогичная конфигурация
```

2. Создать `monitoring/config-ds3.yaml`

3. Обновить конфигурацию Prometheus в `monitoring/prometheus.yml`:
```yaml
  - job_name: '389ds-ds3'
    static_configs:
      - targets: ['ds3-exporter:9313']
```

4. Перезапустить стек:
```bash
docker-compose -f docker-compose-monitoring.yml up -d
```

---

## Интеграция с существующей установкой

### Миграция с установки docker.md

Если у вас есть существующие ds1/ds2 из [docker.md](docker.md):

1. **Остановить существующие контейнеры**:
```bash
docker stop ds1 ds2
docker rm ds1 ds2
```

2. **Мигрировать volumes с данными** (при необходимости):
```bash
# docker-compose-monitoring.yml использует именованные volumes: ds1_data, ds2_data
# Если у вас bind mounts, обновите секцию volumes в docker-compose-monitoring.yml
```

3. **Запустить стек мониторинга**:
```bash
docker-compose -f docker-compose-monitoring.yml up -d
```

### Добавление мониторинга к существующему docker-compose.yml

Вместо использования docker-compose-monitoring.yml, вы можете добавить сервисы к существующей установке:

```bash
# Скопировать сервисы мониторинга
cat docker-compose-monitoring.yml >> your-docker-compose.yml

# Отредактировать для избежания дубликатов и настроить при необходимости

# Запустить обновленный стек
docker-compose up -d
```

---

## Следующие шаги

### Развертывание в Kubernetes
Для production развертывания в Kubernetes с StatefulSets и Helm:
- [Руководство по Kubernetes манифестам](../kubernetes/README.md)
- [Руководство по Helm Chart](../artds/README.md)

### Расширенный мониторинг
- Настроить **Alertmanager** для уведомлений
- Настроить **правила записи** для сложных запросов
- Создать **пользовательские дашборды** для конкретных сценариев использования
- Интегрировать с **Loki** для агрегации логов

### Автоматизация
- Автоматизировать provisioning дашбордов с помощью Terraform
- CI/CD для обновлений exporter
- Автомасштабирование на основе метрик

---

## Ссылки

- [Документация 389 Directory Server](https://www.port389.org/docs/389ds/documentation.html)
- [Документация Prometheus](https://prometheus.io/docs/)
- [Документация Grafana](https://grafana.com/docs/)
- [ozgurcd/389DS-exporter](https://github.com/ozgurcd/389DS-exporter) - Справочный паттерн Exporter
