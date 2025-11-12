# Artds Helm Chart

Helm chart для установки LDAP сервера 389 Directory Server (389ds) в multi-master конфигурации.

## 📚 Обучающий материал

Этот Helm chart является частью образовательного проекта, демонстрирующего эволюцию развертывания 389ds:

**Stage 1:** [Docker deployment](../docker.md) - Базовое развертывание через Docker
**Stage 2:** [Kubernetes manifests](../kubernetes/README.md) - Развертывание через Kubernetes манифесты
**Stage 3:** **Helm chart** - Автоматизация через Helm (этот документ)

## 🎯 Назначение

Production-ready Helm chart с функциями:
- ✅ Автоматическая multi-master репликация (2 реплики)
- ✅ TLS/LDAPS через cert-manager
- ✅ Автоматическая инициализация плагинов (MemberOf, Retro Changelog)
- ✅ Автоматическая инициализация LDAP дерева
- ✅ High Availability через pod anti-affinity
- ✅ Persistent storage для каждой реплики
- ✅ JSON formatted logging с гибкой конфигурацией

## ⚙️ Архитектурные ограничения

В чарте зафиксировано:

* **Максимальное количество реплик: 2** - архитектура 389ds поддерживает больше, но требует усложнения init-скрипта
* **Pod Anti-Affinity** - поды принудительно размещаются на разных worker нодах для HA

---

## 🚀 Quick Start

### Предварительные требования

1. Kubernetes кластер (1 control plane + 2+ worker nodes)
2. Helm 3.x установлен
3. kubectl настроен для доступа к кластеру
4. cert-manager установлен с ClusterIssuer `dev-ca-issuer`
5. StorageClass `managed-nfs-storage` доступен
6. (Опционально) MetalLB для LoadBalancer services

### Установка

```bash
# Клонировать репозиторий
git clone <repository-url>
cd artds

# Установить chart
helm install artds ./artds -n artldap --create-namespace

# Проверить статус
kubectl get pods -n artldap -w
kubectl get certificates -n artldap
kubectl get pvc -n artldap
```

### Проверка работоспособности

```bash
# Проверить логи инициализации
kubectl logs -n artldap job/artds-init -f
kubectl logs -n artldap job/artds-infra -f

# Проверить статус репликации
kubectl exec -n artldap artds-0 -- dsconf localhost replication get-status
kubectl exec -n artldap artds-1 -- dsconf localhost replication get-status

# Проверить плагины
kubectl exec -n artldap artds-0 -- dsconf localhost plugin memberof show
kubectl exec -n artldap artds-0 -- dsconf localhost plugin "Retro Changelog" show

# Тестовый LDAP поиск
kubectl exec -n artldap artds-0 -- ldapsearch -H ldap://localhost:3389 \
  -D "cn=Directory Manager" -w password \
  -b "dc=test,dc=local" -s sub "(objectClass=*)"

# Просмотр JSON логов
kubectl logs -n artldap artds-0 -f | jq .
```

---

## 📝 JSON Logging Configuration

Начиная с версии chart 0.1.0, поддерживается автоматическая настройка JSON логирования для всех логов 389ds (Access, Error, Audit).

### Настройка через values.yaml

JSON логирование настраивается в секции `logging` файла [values.yaml:169-186](values.yaml#L169-L186):

```yaml
# JSON Logging Configuration
# Supported since 389ds 3.0+ (Audit Log requires 3.1.1+)
logging:
  # Enable JSON formatted logs (requires pod restart)
  jsonFormat:
    enable: true  # Set to false for default plain text format

    # Log format options: default | json | json-pretty
    accessLog: json
    errorLog: json
    auditLog: json  # Requires 389ds 3.1.1+

  # Time format (strftime specification)
  # Default: ISO 8601 with timezone
  timeFormat:
    accessLog: "%Y-%m-%dT%H:%M:%S%z"
    errorLog: "%Y-%m-%dT%H:%M:%S%z"
    auditLog: "%Y-%m-%dT%H:%M:%S%z"
```

### Форматы логов

**Доступные значения для `log-format`:**

| Формат | Описание | Использование |
|--------|----------|---------------|
| `default` | Стандартный текстовый формат | Legacy интеграции |
| `json` | Компактный JSON | Production, log aggregation |
| `json-pretty` | Форматированный JSON | Development, debugging |

**Примеры:**

```bash
# json - компактный
{"date":"12/11/2025 14:23:45+0000","utc_time":"2025-11-12T14:23:45.123+00:00","level":"INFO","operation":"BIND"}

# json-pretty - форматированный
{
  "date": "12/11/2025 14:23:45+0000",
  "utc_time": "2025-11-12T14:23:45.123+00:00",
  "level": "INFO",
  "operation": "BIND"
}
```

### Настройка для разных окружений

#### Production окружение

```yaml
# values-prod.yaml
logging:
  jsonFormat:
    enable: true
    accessLog: json       # Компактный формат
    errorLog: json
    auditLog: json
  timeFormat:
    accessLog: "%Y-%m-%dT%H:%M:%S%z"
    errorLog: "%Y-%m-%dT%H:%M:%S%z"
    auditLog: "%Y-%m-%dT%H:%M:%S%z"
```

```bash
helm install artds ./artds -n prod -f values-prod.yaml
```

#### Test/Dev окружение

```yaml
# values-test.yaml
logging:
  jsonFormat:
    enable: true
    accessLog: json-pretty  # Pretty format для отладки
    errorLog: json-pretty
    auditLog: json
  timeFormat:
    accessLog: "%Y-%m-%dT%H:%M:%S%z"
    errorLog: "%Y-%m-%dT%H:%M:%S%z"
    auditLog: "%Y-%m-%dT%H:%M:%S%z"
```

```bash
helm install artds ./artds -n test -f values-test.yaml
```

#### Отключение JSON логирования

```yaml
# values-legacy.yaml
logging:
  jsonFormat:
    enable: false  # Используется default text format
```

### Применение изменений

После изменения конфигурации логирования необходим перезапуск подов:

```bash
# Метод 1: Helm upgrade (рекомендуется)
helm upgrade artds ./artds -n artldap -f values-prod.yaml

# Метод 2: Ручной перезапуск StatefulSet
kubectl rollout restart statefulset/artds -n artldap
kubectl rollout status statefulset/artds -n artldap
```

### Просмотр и анализ JSON логов

#### Базовый просмотр

```bash
# Просмотр всех логов с форматированием
kubectl logs -n artldap artds-0 -f | jq .

# Только последние 100 записей
kubectl logs -n artldap artds-0 --tail=100 | jq .

# Логи всех подов одновременно
kubectl logs -n artldap -l app.kubernetes.io/name=artds -f | jq .
```

#### Фильтрация

```bash
# Только ошибки
kubectl logs -n artldap artds-0 | jq 'select(.level == "ERROR")'

# Операции конкретного пользователя
kubectl logs -n artldap artds-0 | jq 'select(.bind_dn | contains("uid=testuser"))'

# BIND операции
kubectl logs -n artldap artds-0 | jq 'select(.operation == "BIND")'

# Медленные запросы (etime > 1 сек)
kubectl logs -n artldap artds-0 | jq 'select(.etime > 1.0)'

# Ошибки аутентификации
kubectl logs -n artldap artds-0 | jq 'select(.operation == "BIND" and .result != 0)'
```

#### Статистика

```bash
# Топ-10 пользователей
kubectl logs -n artldap artds-0 --tail=10000 | \
  jq -r '.bind_dn' | sort | uniq -c | sort -rn | head -10

# Средняя скорость операций
kubectl logs -n artldap artds-0 --tail=1000 | \
  jq -s 'map(.etime) | add/length'

# Количество операций по типам
kubectl logs -n artldap artds-0 --tail=5000 | \
  jq -r '.operation' | sort | uniq -c | sort -rn
```

### Интеграция с системами мониторинга

#### Prometheus/Loki

Для интеграции с Loki используйте Promtail:

```yaml
# promtail-config.yaml
- job_name: artds
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
          - artldap
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
      regex: artds
      action: keep
  pipeline_stages:
    - json:
        expressions:
          level: level
          operation: operation
          bind_dn: bind_dn
    - labels:
        level:
        operation:
```

#### ELK Stack

Для интеграции с Elasticsearch используйте Filebeat:

```yaml
# filebeat-config.yaml
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/artds-*.log
    json.keys_under_root: true
    json.add_error_key: true
    processors:
      - add_kubernetes_metadata:
          host: ${NODE_NAME}
```

### Версионная совместимость

| 389ds Version | Access Log JSON | Error Log JSON | Audit Log JSON |
|---------------|----------------|----------------|----------------|
| 3.0.x | ✅ | ✅ | ❌ |
| 3.1.0 | ✅ | ✅ | ❌ |
| 3.1.1+ | ✅ | ✅ | ✅ |

**Примечание:** При использовании 389ds < 3.1.1, команда настройки Audit JSON будет игнорироваться с предупреждением в логах init-job.

### Troubleshooting

#### JSON логи не появляются

**Проверить конфигурацию:**
```bash
kubectl exec -n artldap artds-0 -- dsconf localhost logging access show | grep log-format
kubectl exec -n artldap artds-0 -- dsconf localhost logging error show | grep log-format
```

**Ожидаемый результат:**
```
log-format: json
```

**Если формат не JSON:**
```bash
# Проверить значения в values.yaml
helm get values artds -n artldap

# Проверить логи init-job
kubectl logs -n artldap job/artds-init | jq 'select(.message | contains("JSON"))'

# Ручная настройка (временное решение)
kubectl exec -n artldap artds-0 -- dsconf localhost logging access set log-format json
```

#### Логи не парсятся в Loki/ELK

**Проверить формат timestamp:**
```bash
kubectl logs -n artldap artds-0 --tail=1 | jq -r '.utc_time'
```

**Ожидаемый формат:** `2025-11-12T14:23:45+0000`

**Если формат другой:**
```bash
# Проверить timeFormat в values.yaml
helm get values artds -n artldap | grep timeFormat

# Исправить в values.yaml и обновить
helm upgrade artds ./artds -n artldap -f values.yaml
```

---

## 📖 От Kubernetes манифестов к Helm

### Проблемы с Kubernetes манифестами

При работе с [Kubernetes манифестами](../kubernetes/README.md) (Stage 2) мы столкнулись с проблемами:

| Проблема | Пример | Последствие |
|----------|--------|-------------|
| **Дублирование кода** | DNS имена в 7+ местах | Ошибки при копировании |
| **Хардкод значений** | Namespace "artldap" в каждом файле | Невозможность переиспользования |
| **Отсутствие версионирования** | 11 отдельных YAML файлов | Сложно отследить изменения |
| **Ручной порядок применения** | `kubectl apply -f 01-*.yaml` затем `02-*.yaml`... | Ошибки последовательности |
| **Нет валидации** | Опечатки находятся только при запуске | Долгий цикл отладки |
| **Сложность обновления** | Изменить суффикс - правка 6+ файлов | Высокий риск ошибок |

### Как Helm решает эти проблемы

#### 1. Темплейтизация - устранение дублирования

**Было (Kubernetes):**
```yaml
# 07-statefulset.yaml
spec:
  serviceName: artds-hl  # Hardcoded

# 08-services.yaml
metadata:
  name: artds-hl  # Дублирование

# 05-configmap-init.yaml
DS_HL_SVC_NAME: "artds-hl"  # Еще одно дублирование
```

**Стало (Helm):**
```yaml
# values.yaml
fullnameOverride: "artds"  # Определено один раз

# templates/statefulset.yaml
spec:
  serviceName: {{ include "artds.fullname" . }}-hl  # Генерируется

# templates/service-headless.yaml
metadata:
  name: {{ include "artds.fullname" . }}-hl  # Генерируется

# templates/configmap-init.yaml
DS_HL_SVC_NAME: "{{ include "artds.fullname" . }}-hl"  # Генерируется
```

#### 2. Централизованная конфигурация

**Было (Kubernetes):**
```yaml
# 03-secrets.yaml
namespace: artldap

# 07-statefulset.yaml
namespace: artldap

# 08-services.yaml
namespace: artldap

# Изменить namespace = править 11 файлов
```

**Стало (Helm):**
```yaml
# values.yaml - ОДИН источник правды
ds:
  suffix: "dc=test,dc=local"

# Helm автоматически подставляет namespace из install command
# helm install artds ./artds -n <любой-namespace>
```

#### 3. Версионирование и rollback

```bash
# Kubernetes - нет версионирования
kubectl apply -f kubernetes/  # Какая версия? Неизвестно

# Helm - автоматическое версионирование
helm install artds ./artds -n artldap     # Release 1
helm upgrade artds ./artds -n artldap     # Release 2
helm rollback artds 1 -n artldap          # Откат к Release 1
helm history artds -n artldap             # История изменений
```

#### 4. Автоматический порядок применения

```bash
# Kubernetes - ручной контроль порядка
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-storage.yaml
kubectl apply -f 03-secrets.yaml
# ... 11 команд в правильном порядке

# Helm - автоматическая сортировка через hook weights
helm install artds ./artds -n artldap
# Helm сам определяет порядок через annotations:
#   "helm.sh/hook-weight": "-5"  # Сначала
#   "helm.sh/hook-weight": "0"   # Потом
#   "helm.sh/hook-weight": "5"   # В конце
```

#### 5. Встроенная валидация

```bash
# Kubernetes - нет pre-deployment валидации
kubectl apply -f broken.yaml  # Ошибка найдена только после apply

# Helm - множество уровней проверки
helm lint ./artds                          # Проверка структуры chart
helm template artds ./artds | kubectl apply --dry-run=server -f -  # Валидация в кластере
helm upgrade artds ./artds -n artldap --dry-run  # Симуляция обновления
```

#### 6. Условная логика

**Было (Kubernetes):**
```yaml
# 08-services.yaml - всегда создаются per-pod services
# Даже если не нужны - приходится комментировать/удалять
```

**Стало (Helm):**
```yaml
# values.yaml
services:
  servicePerPod:
    enable: false  # Просто переключатель

# templates/service-per-pod.yaml
{{- if .Values.services.servicePerPod.enable }}
# Создается только если enable: true
{{- end }}
```

#### 7. Переиспользование и шаринг

```bash
# Kubernetes - копирование 11 файлов
cp -r kubernetes/ my-project/
# + Править все хардкод значения вручную

# Helm - параметризованная установка
helm install prod-ldap ./artds -n prod \
  --set ds.suffix="dc=prod,dc=company,dc=com" \
  --set services.main.annotations."metallb\.io/loadBalancerIPs"="10.0.0.100" \
  --set persistence.storageSize="10Gi"
# Те же самые templates, разная конфигурация
```

### Сравнительная таблица

| Аспект | Kubernetes Manifests | Helm Chart |
|--------|---------------------|------------|
| Дублирование конфигурации | ❌ Высокое | ✅ Отсутствует (templates) |
| Управление версиями | ❌ Ручное (git tags) | ✅ Автоматическое (helm history) |
| Откат изменений | ❌ Сложно (git revert + kubectl apply) | ✅ Просто (helm rollback) |
| Порядок применения ресурсов | ❌ Ручной контроль | ✅ Автоматический (hooks, weights) |
| Валидация перед применением | ❌ Нет | ✅ Да (lint, dry-run) |
| Переиспользование | ❌ Copy-paste | ✅ Параметризация |
| Условная логика | ❌ Нет | ✅ Да (if/else, range) |
| Namespace isolation | ❌ Хардкод | ✅ Параметр установки |
| Документация | ❌ Отдельные README | ✅ Встроенная (NOTES.txt) |
| Package management | ❌ Нет | ✅ Да (helm repo, OCI) |

---

## 🛠️ Инкрементальное создание Helm Chart

Этот раздел показывает, как создавать Helm chart **пошагово**, начиная с простейшей структуры и постепенно добавляя функциональность.

### Этап 1: Создание базовой структуры

```bash
# Создать скелет chart
helm create artds-tutorial
cd artds-tutorial

# Удалить ненужные примеры
rm -rf templates/*
rm values.yaml

# Создать минимальную структуру
mkdir -p templates

# Создать Chart.yaml
cat > Chart.yaml <<EOF
apiVersion: v2
name: artds
description: 389 Directory Server Helm chart
version: 0.1.0
appVersion: "3.1"
EOF

# Создать минимальный values.yaml
cat > values.yaml <<EOF
replicaCount: 2

image:
  repository: 389ds/dirsrv
  tag: "3.1"

ds:
  suffix: "dc=test,dc=local"
EOF
```

**Что получилось:**
```
artds-tutorial/
├── Chart.yaml           # Метаданные chart
├── values.yaml          # Конфигурация
└── templates/           # Пока пусто
```

### Этап 2: Конвертация Secret

Начнем с простейшего ресурса из [kubernetes/](../kubernetes/).

> **Примечание:** Namespace НЕ создается через Helm template. В Helm charts namespace указывается при установке командой `helm install -n <namespace> --create-namespace`. Поэтому `kubernetes/01-namespace.yaml` не конвертируется в template.

**Взять исходник:** `kubernetes/03-secrets.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: artds-admin-secret  # Хардкод
  namespace: artldap        # Хардкод
stringData:
  DS_DM_PASSWORD: password  # Хардкод
```

**Конвертировать в template:** `templates/secret.yaml`
```yaml
{{- if not .Values.ds.adminSecretName }}  # Условие: создавать только если не указан внешний Secret
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "artds.fullname" . }}-admin-secret  # Генерируемое имя
  namespace: {{ .Release.Namespace }}                   # Автоподстановка
  labels:
    {{- include "artds.labels" . | nindent 4 }}
type: Opaque
stringData:
  DS_DM_PASSWORD: {{ .Values.ds.adminPassword | quote }}   # Из values.yaml
  DS_REPL_PASSWORD: {{ .Values.ds.replPassword | quote }}  # Из values.yaml
{{- end }}
```

**Обновить values.yaml:**
```yaml
ds:
  suffix: "dc=test,dc=local"
  adminSecretName: ""        # Пустое = создавать Secret
  adminPassword: password    # Значение по умолчанию
  replPassword: password
```

**Протестировать:**
```bash
# Рендеринг templates без установки
helm template artds-tutorial .

# Проверка валидности
helm lint .

# Dry-run установки
helm install artds-tutorial . --dry-run --debug
```

### Этап 3: Создание helpers (_helpers.tpl)

Хелперы - это переиспользуемые шаблонные функции для генерации имен, labels, selectors.

**Создать:** `templates/_helpers.tpl`
```yaml
{{/*
Полное имя приложения
*/}}
{{- define "artds.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Общие labels
*/}}
{{- define "artds.labels" -}}
helm.sh/chart: {{ include "artds.chart" . }}
{{ include "artds.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "artds.selectorLabels" -}}
app.kubernetes.io/name: {{ include "artds.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "artds.fullname" . }}
component: directory-server
{{- end }}

{{/*
Имя chart
*/}}
{{- define "artds.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Имя приложения
*/}}
{{- define "artds.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Имя Secret с паролями
*/}}
{{- define "artds.adminSecretName" -}}
{{- if .Values.ds.adminSecretName }}
{{- .Values.ds.adminPassword}}
{{- else }}
{{- include "artds.fullname" . }}-admin-secret
{{- end }}
{{- end }}
```

**Использование в templates:**
```yaml
# До (хардкод)
metadata:
  name: artds-admin-secret

# После (функция)
metadata:
  name: {{ include "artds.fullname" . }}-admin-secret
  labels:
    {{- include "artds.labels" . | nindent 4 }}
```

### Этап 4: Конвертация StatefulSet

Самый сложный ресурс - StatefulSet с множеством зависимостей.

**Взять исходник:** `kubernetes/07-statefulset.yaml` (203 строки)

**Ключевые преобразования:**

1. **Имена и labels:**
```yaml
# До
metadata:
  name: artds

# После
metadata:
  name: {{ include "artds.fullname" . }}
  labels:
    {{- include "artds.labels" . | nindent 4 }}
```

2. **Replicas и image:**
```yaml
# До
replicas: 2
image: 389ds/dirsrv:3.1

# После
replicas: {{ .Values.replicaCount }}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
```

3. **Environment variables:**
```yaml
# До
env:
  - name: DS_SUFFIX_NAME
    value: "dc=test,dc=local"

# После
env:
  - name: DS_SUFFIX_NAME
    value: {{ .Values.ds.suffix | quote }}
  - name: DS_DM_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ include "artds.adminSecretName" . }}  # Функция-хелпер
        key: DS_DM_PASSWORD
```

4. **Условные ресурсы:**
```yaml
# До
resources:
  requests:
    cpu: "1"
    memory: "512Mi"

# После
resources:
  {{- toYaml .Values.resources | nindent 10 }}  # Полная подстановка из values.yaml
```

5. **Volume mounts:**
```yaml
# До
volumeMounts:
  - name: tls-certs
    mountPath: /data/tls

volumes:
  - name: tls-certs
    secret:
      secretName: artds-tls-secret

# После
volumeMounts:
  {{- if .Values.ssl.enable }}
  - name: tls-certs
    mountPath: /data/tls
    readOnly: true
  {{- end }}

volumes:
  {{- if .Values.ssl.enable }}
  - name: tls-certs
    secret:
      secretName: {{ include "artds.fullname" . }}-tls-secret
  {{- end }}
```

**Результат:** `templates/statefulset.yaml` с полной параметризацией.

### Этап 5: Тестирование и отладка

```bash
# 1. Lint - проверка структуры и синтаксиса
helm lint .

# 2. Template - рендеринг без установки
helm template artds-tutorial . > rendered.yaml
kubectl apply --dry-run=server -f rendered.yaml

# 3. Dry-run - симуляция установки
helm install artds-tutorial . -n artldap --create-namespace --dry-run --debug

# 4. Реальная установка
helm install artds-tutorial . -n artldap --create-namespace

# 5. Проверка статуса
helm list -n artldap
helm status artds-tutorial -n artldap
kubectl get all -n artldap

# 6. Тестирование обновления
# Изменить values.yaml (например, replicaCount: 2 → 1)
helm upgrade artds-tutorial . -n artldap --dry-run --debug
helm upgrade artds-tutorial . -n artldap

# 7. Diff - что изменится
helm diff upgrade artds-tutorial . -n artldap  # Требует helm-diff plugin

# 8. Rollback
helm rollback artds-tutorial 1 -n artldap
```

### Этап 6: Production features

#### 6.1 NOTES.txt - послеустановочная информация

**Создать:** `templates/NOTES.txt`
```
🎉 389 Directory Server установлен!

📋 Полезные команды:

1. Проверить статус подов:
   kubectl get pods -n {{ .Release.Namespace }} -l app.kubernetes.io/instance={{ .Release.Name }}

2. Проверить статус репликации:
   kubectl exec -n {{ .Release.Namespace }} {{ include "artds.fullname" . }}-0 -- \
     dsconf localhost replication get-status

3. Тестовый LDAP поиск:
   kubectl exec -n {{ .Release.Namespace }} {{ include "artds.fullname" . }}-0 -- \
     ldapsearch -H ldap://localhost:3389 -D "cn=Directory Manager" -w {{ .Values.ds.adminPassword }} \
     -b "{{ .Values.ds.suffix }}" "(objectClass=*)"

4. Получить LoadBalancer IP:
{{- if eq .Values.services.main.type "LoadBalancer" }}
   kubectl get svc -n {{ .Release.Namespace }} {{ include "artds.fullname" . }} -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
{{- else }}
   Service type: {{ .Values.services.main.type }} (LoadBalancer не используется)
{{- end }}

📖 Документация: https://github.com/<your-repo>/artds
```

#### 6.2 .helmignore - исключение файлов

**Создать:** `.helmignore`
```
# Patterns to ignore when building packages
.git/
.gitignore
.vscode/
*.swp
*.bak
*.tmp
*.orig
*~
.DS_Store
README.md.backup
docs/
examples/
tests/
```

#### 6.3 values.schema.json - валидация values.yaml

**Создать:** `values.schema.json`
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["replicaCount", "image", "ds"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "maximum": 2,
      "description": "Number of replicas (maximum 2 due to init script limitation)"
    },
    "image": {
      "type": "object",
      "required": ["repository", "tag"],
      "properties": {
        "repository": {
          "type": "string"
        },
        "tag": {
          "type": "string"
        }
      }
    },
    "ds": {
      "type": "object",
      "required": ["suffix", "adminPassword", "replPassword"],
      "properties": {
        "suffix": {
          "type": "string",
          "pattern": "^dc=.+",
          "description": "LDAP suffix (must start with dc=)"
        },
        "adminPassword": {
          "type": "string",
          "minLength": 8
        },
        "replPassword": {
          "type": "string",
          "minLength": 8
        }
      }
    }
  }
}
```

**Валидация:**
```bash
# Helm автоматически проверит values.yaml против schema при установке
helm install artds-tutorial . -n artldap

# Ручная проверка через yq/jq
cat values.yaml | yq -o=json | jq . > values.json
ajv validate -s values.schema.json -d values.json
```

#### 6.4 dependencies - работа с зависимостями

**Если chart зависит от других charts (например, cert-manager):**

**Обновить Chart.yaml:**
```yaml
apiVersion: v2
name: artds
version: 0.1.0
appVersion: "3.1"

dependencies:
  - name: cert-manager
    version: "1.13.x"
    repository: "https://charts.jetstack.io"
    condition: certManager.install  # Условная установка
```

**Обновить values.yaml:**
```yaml
certManager:
  install: false  # По умолчанию не устанавливать (предполагаем уже установлен)
```

**Управление зависимостями:**
```bash
# Скачать зависимости
helm dependency update .

# Просмотр зависимостей
helm dependency list .

# Установка с зависимостями
helm install artds-tutorial . -n artldap --set certManager.install=true
```

### Этап 7: Упаковка и распространение

#### 7.1 Package - создание .tgz архива

```bash
# Создать пакет
helm package .
# Результат: artds-0.1.0.tgz

# Создать index для Helm repository
helm repo index . --url https://charts.example.com

# Результат: index.yaml с метаданными
```

#### 7.2 Публикация в Helm repository

**Option A: GitHub Pages**
```bash
# 1. Создать gh-pages ветку
git checkout --orphan gh-pages

# 2. Добавить chart
helm package ../artds
helm repo index . --url https://<username>.github.io/<repo>

# 3. Commit и push
git add .
git commit -m "Publish artds chart"
git push origin gh-pages

# 4. Использование
helm repo add myrepo https://<username>.github.io/<repo>
helm install artds myrepo/artds
```

**Option B: OCI registry (Harbor, GitHub Container Registry)**
```bash
# 1. Логин
helm registry login ghcr.io -u <username>

# 2. Package
helm package .

# 3. Push
helm push artds-0.1.0.tgz oci://ghcr.io/<username>

# 4. Использование
helm install artds oci://ghcr.io/<username>/artds --version 0.1.0
```

### Итоговая структура Helm chart

```
artds/
├── Chart.yaml                    # Метаданные: name, version, appVersion
├── values.yaml                   # Конфигурация по умолчанию
├── values.schema.json            # JSON Schema валидация
├── .helmignore                   # Исключения при package
├── README.md                     # Документация (этот файл)
├── templates/
│   ├── _helpers.tpl              # Переиспользуемые функции
│   ├── NOTES.txt                 # Послеустановочные инструкции
│   ├── secret.yaml               # Пароли админа/репликации
│   ├── certificate.yaml          # cert-manager Certificate
│   ├── configmap-init.yaml       # Bash скрипт инициализации
│   ├── configmap-infra.yaml      # LDIF для структуры дерева
│   ├── statefulset.yaml          # Основной workload
│   ├── service.yaml              # LoadBalancer service
│   ├── service-headless.yaml     # Headless service для StatefulSet
│   ├── service-per-pod.yaml      # Per-pod services (conditional)
│   ├── job-init.yaml             # Job инициализации репликации
│   ├── job-infra.yaml            # Job инициализации LDAP дерева
│   ├── rbac.yaml                 # ServiceAccount, Role, RoleBinding
│   └── tests/                    # Helm tests (опционально)
│       └── test-connection.yaml
└── charts/                       # Зависимости (если есть)

Примечание: namespace.yaml НЕ включен, т.к. namespace создается командой helm install -n <name> --create-namespace
```

---

## 🔌 Инициализация плагинов

Helm chart поддерживает два подхода к настройке плагинов 389ds:

### Подход 1: Автоматический (по умолчанию)

**Активация:** `jobs.init.enable: true` (включено в values.yaml)

**Что делает Job init:**
1. Ожидает готовности обоих подов StatefulSet
2. Создает backends `userRoot` на обеих репликах
3. Включает репликацию на обоих подах
4. Создает replication agreements (двусторонние)
5. Инициализирует репликацию (только pod-0 → pod-1 с флагом `--init`)
6. **Включает плагины:**
   - MemberOf Plugin
   - Retro Changelog Plugin
7. Перезапускает StatefulSet (через patch аннотации)

**Преимущества:**
- ✅ Полная автоматизация - "helm install" и всё готово
- ✅ Консистентность - плагины включаются одинаково на всех репликах
- ✅ Переиспользование - работает при каждой установке chart
- ✅ Нет ручных команд

**Недостатки:**
- ⚠️ Рестарт подов после включения плагинов (требует downtime ~30 сек)
- ⚠️ Сложнее отлаживать при проблемах
- ⚠️ Требует RBAC прав для Job (патчинг StatefulSet)

**Как это работает:**

Фрагмент из `templates/configmap-init.yaml` (скрипт в Job):
```bash
# Включение плагинов на обоих подах
for I in $(seq 0 $((NUMBER_OF_REPLICAS - 1))); do
  POD_FQDN="${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}.${K8S_NAMESPACE}.svc.cluster.local"

  echo "🔌 Включение плагинов на ${POD_FQDN}..."

  # MemberOf Plugin
  dsconf -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
    ldap://${POD_FQDN}:${DS_SVC_PORT} plugin memberof enable

  # Retro Changelog Plugin
  dsconf -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
    ldap://${POD_FQDN}:${DS_SVC_PORT} plugin "Retro Changelog" enable
done

# Рестарт StatefulSet через Kubernetes API
kubectl -n ${K8S_NAMESPACE} patch statefulset ${DS_POD_NAME} \
  -p '{"spec":{"template":{"metadata":{"annotations":{"restartedAt":"'$(date +%s)'"}}}}}'
```

### Подход 2: Ручной

**Активация:** `jobs.init.enable: false` в values.yaml ИЛИ при установке:
```bash
helm install artds ./artds -n artldap --set jobs.init.enable=false
```

**Что нужно сделать вручную после установки:**

```bash
# 1. Дождаться готовности подов
kubectl wait --for=condition=ready pod -l app=artds -n artldap --timeout=300s

# 2. Подключиться к pod-0
kubectl exec -it -n artldap artds-0 -- bash

# 3. Создать backend userRoot
dsconf localhost backend create \
  --suffix "dc=test,dc=local" \
  --be-name userRoot

# 4. Включить репликацию
dsconf localhost replication enable \
  --suffix "dc=test,dc=local" \
  --role supplier \
  --replica-id 1

# 5. Создать Replication Manager
dsconf localhost replication create-manager \
  --name "Replication Manager" \
  --passwd "password"

# 6. Включить плагины
dsconf localhost plugin memberof enable
dsconf localhost plugin "Retro Changelog" enable

# 7. Рестарт для применения плагинов
dsctl localhost restart

# 8. Повторить шаги 2-7 на pod-1 (replica-id 2)
kubectl exec -it -n artldap artds-1 -- bash
# ...

# 9. Создать replication agreements
# На pod-0:
dsconf localhost replication create-agmt \
  --suffix "dc=test,dc=local" \
  --host "artds-1.artds-hl.artldap.svc.cluster.local" \
  --port 3389 \
  --bind-dn "cn=replication manager,cn=config" \
  --bind-passwd "password" \
  --bind-method simple \
  --init \
  meTo1

# На pod-1:
dsconf localhost replication create-agmt \
  --suffix "dc=test,dc=local" \
  --host "artds-0.artds-hl.artldap.svc.cluster.local" \
  --port 3389 \
  --bind-dn "cn=replication manager,cn=config" \
  --bind-passwd "password" \
  --bind-method simple \
  meTo0

# 10. Проверить статус репликации
dsconf localhost replication get-status
```

**Преимущества:**
- ✅ Полный контроль над каждым шагом
- ✅ Проще отлаживать проблемы
- ✅ Можно настроить плагины индивидуально
- ✅ Нет автоматических рестартов

**Недостатки:**
- ❌ Требует ручного выполнения команд
- ❌ Высокий риск ошибок при копировании команд
- ❌ Долгий процесс настройки
- ❌ Не переиспользуется между установками

### Сравнительная таблица подходов

| Аспект | Автоматический (Job) | Ручной (kubectl exec) |
|--------|---------------------|----------------------|
| Время настройки | ~5 минут (автоматически) | ~30 минут (ручные команды) |
| Риск ошибок | Низкий | Высокий |
| Переиспользование | Да (helm install) | Нет (повторять каждый раз) |
| Отладка | Сложнее | Проще |
| Downtime | ~30 сек (рестарт) | Зависит от действий |
| RBAC требования | Да (патчинг StatefulSet) | Нет |
| Production readiness | ✅ Да | ⚠️ Только для тестирования |

### Рекомендации

- **Для production:** Используйте автоматический подход (`jobs.init.enable: true`)
- **Для обучения/отладки:** Используйте ручной подход для понимания каждого шага
- **При проблемах с Job:** Временно отключите (`enable: false`), настройте вручную, затем верните автоматический режим после устранения проблем

---

## 🚢 Production deployment

### Минимальные требования

```yaml
# values-production.yaml
replicaCount: 2  # Для HA обязательно 2

# Production-grade пароли
ds:
  suffix: "dc=company,dc=com"
  adminSecretName: "artds-admin-secret-prod"  # Внешний Secret

# Ресурсы по результатам load testing
resources:
  requests:
    cpu: "2"
    memory: "2Gi"
  limits:
    cpu: "4"
    memory: "4Gi"

# Persistent storage
persistence:
  storageClassName: "fast-ssd"  # Производительный StorageClass
  storageSize: "20Gi"           # Размер под ожидаемый рост данных

# TLS/LDAPS обязательно
ssl:
  enable: true
  certManager:
    issuerRef:
      name: prod-ca-issuer    # Production ClusterIssuer
      kind: ClusterIssuer

# LoadBalancer для внешнего доступа
services:
  main:
    type: LoadBalancer
    annotations:
      metallb.io/loadBalancerIPs: "10.0.0.100"  # Production IP

# Обязательная автоматическая инициализация
jobs:
  init:
    enable: true
  infra:
    enable: true
```

### Установка в production

```bash
# 1. Создать namespace
kubectl create namespace artldap-prod

# 2. Создать Secret с сильными паролями
kubectl create secret generic artds-admin-secret-prod \
  -n artldap-prod \
  --from-literal=DS_DM_PASSWORD='<strong-password>' \
  --from-literal=DS_REPL_PASSWORD='<strong-replication-password>'

# 3. Установить chart
helm install artds-prod ./artds \
  -n artldap-prod \
  -f values-production.yaml

# 4. Мониторинг установки
watch kubectl get pods,pvc,svc -n artldap-prod

# 5. Проверить готовность
kubectl wait --for=condition=ready pod -l app=artds -n artldap-prod --timeout=600s

# 6. Проверить Job инициализации
kubectl logs -n artldap-prod job/artds-prod-init -f

# 7. Проверить репликацию
kubectl exec -n artldap-prod artds-prod-0 -- dsconf localhost replication get-status
```

### Мониторинг и алерты

Рекомендуется настроить:
- **Prometheus metrics** - экспортер 389ds (если доступен)
- **Liveness/Readiness probes** - уже настроены в chart
- **PVC monitoring** - отслеживание заполнения дисков
- **Replication lag** - через dsconf или ldapsearch

### Backup стратегия

```bash
# Backup через ldapsearch (экспорт в LDIF)
kubectl exec -n artldap-prod artds-prod-0 -- \
  ldapsearch -H ldap://localhost:3389 \
  -D "cn=Directory Manager" -w '<password>' \
  -b "dc=company,dc=com" \
  -s sub "(objectClass=*)" > backup-$(date +%Y%m%d).ldif

# Backup через dsctl (database export)
kubectl exec -n artldap-prod artds-prod-0 -- \
  dsctl localhost db2ldif userRoot

# Backup PVC (через VolumeSnapshot если поддерживается)
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: artds-backup-$(date +%Y%m%d)
  namespace: artldap-prod
spec:
  source:
    persistentVolumeClaimName: data-artds-prod-0
EOF
```

---

## 🐛 Troubleshooting

### Проблема 1: Pods не запускаются (Pending)

**Причина:** Pod anti-affinity требует 2+ worker нод

**Решение:**
```bash
# Проверить количество worker нод
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane'

# Если нода только одна - временно отключить anti-affinity
helm upgrade artds ./artds -n artldap \
  --set podAntiAffinity.enabled=false  # Добавить параметр в values.yaml
```

### Проблема 2: Job init падает с ошибкой RBAC

**Причина:** ServiceAccount не имеет прав на патчинг StatefulSet

**Решение:**
```bash
# Проверить RBAC
kubectl get role,rolebinding -n artldap
kubectl describe role artds-init-role -n artldap

# Если нет - применить
kubectl apply -f templates/rbac.yaml
```

### Проблема 3: Репликация не работает

**Диагностика:**
```bash
# Проверить replication agreements
kubectl exec -n artldap artds-0 -- dsconf localhost replication list --suffix "dc=test,dc=local"

# Проверить статус репликации
kubectl exec -n artldap artds-0 -- dsconf localhost replication get-status

# Проверить ошибки репликации
kubectl exec -n artldap artds-0 -- grep -i repl /var/log/dirsrv/slapd-*/errors
```

**Решение:** Переинициализация репликации
```bash
# На pod-0
kubectl exec -it -n artldap artds-0 -- \
  dsconf localhost repl-agmt init \
  --suffix "dc=test,dc=local" meTo1
```

### Проблема 4: Плагины не активны

**Проверка:**
```bash
kubectl exec -n artldap artds-0 -- dsconf localhost plugin memberof show | grep enabled
kubectl exec -n artldap artds-0 -- dsconf localhost plugin "Retro Changelog" show | grep enabled
```

**Решение:** Ручное включение (если `jobs.init.enable: false`)
```bash
kubectl exec -it -n artldap artds-0 -- bash
dsconf localhost plugin memberof enable
dsconf localhost plugin "Retro Changelog" enable
dsctl localhost restart
```

### Проблема 5: TLS сертификаты не выпускаются

**Диагностика:**
```bash
# Проверить Certificate ресурс
kubectl describe certificate -n artldap

# Проверить CertificateRequest
kubectl get certificaterequests -n artldap

# Проверить ClusterIssuer
kubectl describe clusterissuer dev-ca-issuer
```

**Решение:** Убедиться, что cert-manager установлен и ClusterIssuer настроен
```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
```

### Проблема 6: Helm upgrade падает с ошибкой immutable field

**Причина:** StatefulSet volumeClaimTemplates нельзя изменять

**Решение:**
```bash
# Option 1: Удалить и переустановить (потеря данных!)
helm uninstall artds -n artldap
kubectl delete pvc -n artldap --all
helm install artds ./artds -n artldap

# Option 2: Ручной патч StatefulSet
kubectl delete statefulset artds -n artldap --cascade=orphan
helm upgrade artds ./artds -n artldap
```

---

## 📚 values file

Полное описание всех параметров конфигурации chart.

Количество подов. Не более 2-х.

```yaml
replicaCount: 2
```

Контейнер ds сервера.

```yaml
image:
  repository: 389ds/dirsrv
  pullPolicy: IfNotPresent
  tag: "3.1"
```

Init контейнер. Используется в поде StatefulSet.

```yaml
initImage:
  repository: busybox
  pullPolicy: IfNotPresent
  tag: "1.37.0"
```

Secret , используемый для pull образов из хранилища контейнеров.

```yaml
imagePullSecrets: []
```

Изменение имени ресурсов по умолчанию. Не рекомендуется использовать, если в одном namespace планируется устанавливать несколько чартов.

```yaml
nameOverride: ""
fullnameOverride: ""
```

Дополнительные аннотации и метки на подах.

```yaml
podAnnotations: {}
podLabels: {}
```

Параметры SSL. Для выписывания и дальнейшей работы с SSL сертификатами, рекомендуется использовать установленный в кластере cert-manager.

```yaml
ssl:
  # if false - будет генерироваться самоподписанный сертификат в каждом поде
  # Иначе нужно подставить сертификат во внешний секрет 
  # или использовать kind: Secret от cert-manager
  enable: true
  # Если указано имя секрета - будет использоваться он. cert-manager будет игнорироваться
  secretName: ""
  # cert-manager arguments
  certManager:
    duration:  9125h # 1y
    renewBefore: 360h # 15d
    subject:
      organizations:
      - home dev lab
    isCA: false
    privateKey:
      algorithm: RSA
      encoding: PKCS8
      size: 4096
      rotationPolicy: Always
    usages:
      - server auth
      - client auth
    issuerRef:
      name: dev-ca-issuer
      kind: ClusterIssuer
      group: cert-manager.io
```

Доступ к ds возможен через три типа Sevices: ClusterIP | NodePort | LoadBalancer.

```yaml
services:
  main:
    # ClusterIP | NodePort | LoadBalancer
    type: LoadBalancer
    port: 3389
    name: ldap-tcp
    sslname: ldaps-tcp
    sslport: 3636
    nodePort: ""
    sslNodePort: ""
    annotations: 
      metallb.io/loadBalancerIPs: 192.168.218.181
```

`servicePerPod` вспомогательные сервисы, обеспечивающие индивидуальный доступ к конкретному поду кластера. Применяется когда `replicaCount: 2`.

```yaml
  servicePerPod:
    enable: fale
    pod0:
      type: LoadBalancer
      port: 3389
      name: ldap-tcp
      sslname: ldaps-tcp
      sslport: 3636
      nodePort: ""
      sslNodePort: ""
      annotations: {}
      #  metallb.io/loadBalancerIPs: 192.168.218.182
    pod1:
      type: LoadBalancer
      port: 3389
      name: ldap-tcp
      sslname: ldaps-tcp
      sslport: 3636
      nodePort: ""
      sslNodePort: ""
      annotations: {}
      #  metallb.io/loadBalancerIPs: 192.168.218.183
```

Ресурсы.

```yaml
resources:
  requests:
    cpu: "1"
    memory: "512Mi"
  limits:
    cpu: "1"
    memory: "512Mi"
```

Liveness и readiness пробы.

```yaml
livenessProbe:
  exec:
    command:
    - /usr/lib/dirsrv/dscontainer
    - -H
  initialDelaySeconds: 15
readinessProbe:
  exec:
    command:
    - /usr/lib/dirsrv/dscontainer
    - -H
  initialDelaySeconds: 15
```

Параметры подключаемых томов, где ds будет хранить базу данных. Для каждого пода создаётся отдельный том с указанными параметрами.

```yaml
persistence:
  accessMode: ReadWriteOnce
  storageClassName: managed-nfs-storage   
  storageSize: 1Gi
```

Параметры direcory server-а.

```yaml
ds:
  suffix: "dc=system,dc=local"

  # Пароли суперадмина и реплика менеджера
  # Используются только для первоначальной инициализации
  # Secret с паролями 
  adminSecretName: ""
  # Пример Secret
  # ==============
  # apiVersion: v1
  # kind: Secret
  # type: Opaque
  # stringData:
  #   DS_DM_PASSWORD: password
  #   DS_REPL_PASSWORD: password
  adminPassword: password
  replPassword: password

  # set the log level for `ns-slapd`, default is 266354688
  errorLogLevel: ""
  # set LDBM autotune percentage (`nsslapd-cache-autosize`), default is 25
  autotunePercentage: ""
  # run database reindex task (`db2index`)
  reindex: true
```

После запуска подов ds, возможен запуск jobs которые делают дополнительную настройку ds и заполняют его первоначальными данными.

```yaml
jobs:
  # Первоначальная инициализация, включение модулей, инициализация репликации
  init:
    enable: true
    image:
      repository: 389ds/dirsrv
      pullPolicy: IfNotPresent
      tag: "3.1"
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
  # Инициализация дерева.
  infra:
    enable: true
    image:
      repository: 389ds/dirsrv
      pullPolicy: IfNotPresent
      tag: "3.1"
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
    initConfigModifyLdiff: |
      dn: {{ .Values.ds.suffix }}
      changetype: modify
      add: aci
      aci: (targetattr ="*")(version 3.0;acl "Directory Administrators Group";allow (all) (groupdn = "ldap:///cn=Directory Administrators,{{ .Values.ds.suffix }}");)
      -
      add: aci
      aci: (targetattr="ou || objectClass")(targetfilter="(objectClass=organizationalUnit)")(version 3.0; acl "Enable anyone ou read"; allow (read, search, compare)(userdn="ldap:///anyone");)

    initConfigLdiff: |
      dn: ou=Groups,{{ .Values.ds.suffix }}
      objectClass: organizationalunit
      objectClass: top
      ou: Groups
      aci: (targetattr="cn || member || gidNumber || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_admin to manage groups"; allow (write, add, delete)(groupdn="ldap:///cn=group_admin,ou=permissions,{{ .Values.ds.suffix }}");)
      aci: (targetattr="cn || member || memberUid || gidNumber || nsUniqueId || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable anyone group read"; allow (read, search, compare)(userdn="ldap:///anyone");)
      aci: (targetattr="member")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_modify to alter members"; allow (write)(groupdn="ldap:///cn=group_modify,ou=permissions,{{ .Values.ds.suffix }}");)

      dn: ou=People,{{ .Values.ds.suffix }}
      objectClass: organizationalunit
      objectClass: top
      ou: People
      aci: (targetattr="displayName || legalName || userPassword || nsSshPublicKey")(version 3.0; acl "Enable self partial modify"; allow (write)(userdn="ldap:///self");)
      aci: (targetattr="legalName || telephoneNumber || mobile || sn")(targetfilter="(|(objectClass=nsPerson)(objectClass=inetOrgPerson))")(version 3.0; acl "Enable self legalname read"; allow (read, search, compare)(userdn="ldap:///self");)
      aci: (targetattr="legalName || telephoneNumber")(targetfilter="(objectClass=nsPerson)")(version 3.0; acl "Enable user legalname read"; allow (read, search, compare)(groupdn="ldap:///cn=user_private_read,ou=permissions,{{ .Values.ds.suffix }}");)
      aci: (targetattr="objectClass || description || nsUniqueId || uid || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || nsSshPublicKey || nsAccountLock || userCertificate")(targetfilter="(objectClass=posixaccount)")(version 3.0; acl "Enable anyone user read"; allow (read, search, compare)(userdn="ldap:///anyone");)
      aci: (targetattr="uid || description || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || legalName || telephoneNumber || mobile")(targetfilter="(&(objectClass=nsPerson)(objectClass=nsAccount))")(version 3.0; acl "Enable user admin create"; allow (write, add, delete, read)(groupdn="ldap:///cn=user_admin,ou=permissions,{{ .Values.ds.suffix }}");)
      aci: (targetattr="uid || description || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || legalName || telephoneNumber || mobile")(targetfilter="(&(objectClass=nsPerson)(objectClass=nsAccount))")(version 3.0; acl "Enable user modify to change users"; allow (write, read)(groupdn="ldap:///cn=user_modify,ou=permissions,{{ .Values.ds.suffix }}");)
      aci: (targetattr="userPassword || nsAccountLock || userCertificate || nsSshPublicKey")(targetfilter="(objectClass=nsAccount)")(version 3.0; acl "Enableuser password reset"; allow (write, read)(groupdn="ldap:///cn=user_passwd_reset,ou=permissions,{{ .Values.ds.suffix }}");)

      dn: cn=Directory Administrators,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: Directory Administrators

      dn: ou=Dismissed,{{ .Values.ds.suffix }}
      objectClass: organizationalunit
      objectClass: top
      ou: Dismissed
      description: Dissmissed users
      aci: (targetattr="cn || member || gidNumber || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_admin to manage groups"; allow (write, add, delete)(groupdn="ldap:///cn=group_admin,ou=permissions,{{ .Values.ds.suffix }}");)
      aci: (targetattr="cn || member || memberUid || gidNumber || nsUniqueId || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable anyone group read"; allow (read, search, compare)(userdn="ldap:///anyone");)
      aci: (targetattr="member")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_modify to alter members"; allow (write)(groupdn="ldap:///cn=group_modify,ou=permissions,{{ .Values.ds.suffix }}");)

      dn: ou=permissions,{{ .Values.ds.suffix }}
      objectClass: organizationalunit
      objectClass: top
      ou: permissions

      dn: ou=services,{{ .Values.ds.suffix }}
      objectClass: organizationalunit
      objectClass: top
      ou: services
      aci: (targetattr="objectClass || description || nsUniqueId || cn || memberOf|| nsAccountLock ")(targetfilter="(objectClass=netscapeServer)")(version 3.0; acl "Enable anyone service account read"; allow (read, search, compare)(userdn="ldap:///anyone");)

      dn: cn=group_admin,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: group_admin

      dn: cn=group_modify,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: group_modify

      dn: cn=user_admin,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: user_admin

      dn: cn=user_modify,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: user_modify

      dn: cn=user_passwd_reset,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: user_passwd_reset

      dn: cn=user_private_read,ou=permissions,{{ .Values.ds.suffix }}
      objectClass: groupOfUniqueNames
      objectClass: top
      cn: user_private_read

      # dn: uid=test_admin,ou=People,{{ .Values.ds.suffix }}
      # objectClass: inetOrgPerson
      # objectClass: organizationalPerson
      # objectClass: person
      # objectClass: top
      # cn: Test
      # sn: Admin
      # displayName:: VGVzdCBBZG1pbiAgICAgICAgICAg
      # memberOf: cn=group1,ou=groups,{{ .Values.ds.suffix }}
      # uid: test_admin

      # dn: cn=group1,ou=Groups,{{ .Values.ds.suffix }}
      # objectClass: groupOfUniqueNames
      # objectClass: top
      # cn: group1
      # uniqueMember: uid=test_admin,ou=People,{{ .Values.ds.suffix }}
```

## Установка

```sh
helm install ds artds -n artds --create-namespace
```
