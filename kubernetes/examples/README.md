# Примеры конфигурации Prometheus

Этот каталог содержит примеры конфигураций для мониторинга artds с помощью Prometheus.

## Обзор

Helm chart artds поддерживает два метода сбора метрик Prometheus:

1. **ServiceMonitor** (Prometheus Operator) - Рекомендуется для кластеров с Prometheus Operator
2. **Annotations** (Стандартный Prometheus) - Для vanilla Prometheus развертываний

Этот каталог предоставляет готовые к использованию конфигурации для метода на основе аннотаций.

## Файлы

- `prometheus-manual.yaml` - Полное развертывание Prometheus с обнаружением на основе аннотаций

## Быстрый старт

### 1. Развертывание artds со сбором метрик на основе аннотаций

Настройте установку artds для использования аннотаций:

```bash
# Установка с методом annotations
helm install artds ./artds \
  --namespace artldap \
  --create-namespace \
  --set monitoring.enabled=true \
  --set monitoring.scrapingMethod=annotations

# Или обновление существующей установки
helm upgrade artds ./artds \
  --namespace artldap \
  --set monitoring.scrapingMethod=annotations \
  --reuse-values
```

### 2. Развертывание Prometheus

Разверните экземпляр Prometheus, настроенный для обнаружения на основе аннотаций:

```bash
kubectl apply -f kubernetes/examples/prometheus-manual.yaml
```

Это создаст:
- Namespace `monitoring`
- Prometheus Deployment с RBAC
- ConfigMap с конфигурацией сбора метрик
- PersistentVolumeClaim для хранения метрик
- Service для доступа к UI Prometheus

### 3. Доступ к UI Prometheus

Пробросьте порт для доступа к веб-интерфейсу Prometheus:

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

Откройте http://localhost:9090 в браузере.

### 4. Проверка сбора метрик

В UI Prometheus:

1. Перейдите в **Status → Targets**
2. Найдите job `kubernetes-pods`
3. Убедитесь, что поды artds обнаружены и имеют статус UP
4. Проверьте, что метрики собираются (колонка Last Scrape)

## Детали конфигурации

### Обнаружение на основе аннотаций

Prometheus обнаруживает цели, используя аннотации подов:

```yaml
prometheus.io/scrape: "true"   # Включить сбор метрик
prometheus.io/port: "9313"     # Порт метрик
prometheus.io/path: "/metrics" # Путь к эндпоинту метрик
```

Эти аннотации автоматически добавляются к подам artds когда:
- `monitoring.enabled=true`
- `monitoring.scrapingMethod=annotations`

### Конфигурация сбора метрик

Пример конфигурации Prometheus включает два scrape job:

#### 1. kubernetes-pods (Основной)

Обнаруживает и собирает метрики со всех подов с аннотацией `prometheus.io/scrape: "true"`:

- **Имя Job**: `kubernetes-pods`
- **Обнаружение**: Kubernetes pod role
- **Фильтрация**: Только поды с аннотацией scrape
- **Relabeling**: Добавляет namespace, имя пода, labels, phase, node

#### 2. kubernetes-services (Опциональный)

Обнаруживает сервисы с аннотациями Prometheus:

- **Имя Job**: `kubernetes-services`
- **Обнаружение**: Kubernetes service role
- **Применение**: Агрегированные метрики на уровне сервиса

### Конфигурация хранилища

Настройки хранилища по умолчанию в `prometheus-manual.yaml`:

- **Время хранения**: 15 дней
- **Размер хранения**: 9GB
- **Storage Class**: `managed-nfs-storage` (настройте под вашу среду)
- **Размер PVC**: 10Gi

Чтобы настроить хранилище:

```yaml
# Отредактируйте prometheus-manual.yaml
spec:
  storageClassName: your-storage-class  # Измените на ваш StorageClass
  resources:
    requests:
      storage: 50Gi  # Увеличьте размер при необходимости
```

### Конфигурация ресурсов

Лимиты ресурсов по умолчанию:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi
```

Настройте в соответствии с вашими потребностями мониторинга:
- Больше подов = больше требований к памяти
- Более длительное хранение = больше дискового пространства
- Более частый сбор метрик = больше CPU

## Запросы метрик artds

### Базовые запросы

Проверка активных LDAP подключений:
```promql
ldap_connections_current
```

Скорость подключений в секунду:
```promql
rate(ldap_connections_total[5m])
```

Скорость операций по типам:
```promql
rate(ldap_operations_total[5m])
```

### Запросы по подам

Подключения на конкретном поде:
```promql
ldap_connections_current{kubernetes_pod_name="artds-0"}
```

Сравнение подов:
```promql
ldap_connections_current{kubernetes_namespace="artldap"}
```

### Производительность кэша

Коэффициент попаданий в кэш:
```promql
rate(ldap_backend_entry_cache_hits[5m]) /
rate(ldap_backend_entry_cache_tries[5m])
```

### Примеры алертов

Высокое количество подключений:
```promql
ldap_connections_current > 1000
```

Низкий коэффициент попаданий в кэш:
```promql
(rate(ldap_backend_entry_cache_hits[5m]) /
 rate(ldap_backend_entry_cache_tries[5m])) < 0.8
```

## Переключение между методами сбора метрик

### От Annotations к ServiceMonitor

Если позже установите Prometheus Operator:

```bash
helm upgrade artds ./artds \
  --namespace artldap \
  --set monitoring.scrapingMethod=servicemonitor \
  --set monitoring.serviceMonitor.enabled=true \
  --reuse-values
```

Это:
- Удалит аннотации с подов/сервисов
- Создаст ресурс ServiceMonitor
- Prometheus Operator автоматически обнаружит цели

### От ServiceMonitor к Annotations

Чтобы вернуться к методу на основе аннотаций:

```bash
helm upgrade artds ./artds \
  --namespace artldap \
  --set monitoring.scrapingMethod=annotations \
  --reuse-values
```

Это:
- Удалит ресурс ServiceMonitor
- Добавит аннотации к подам/сервисам
- Ручной Prometheus обнаружит цели

## Настройка

### Пользовательская конфигурация Prometheus

Чтобы добавить пользовательские scrape конфигурации или правила:

1. Отредактируйте секцию ConfigMap в `prometheus-manual.yaml`
2. Добавьте вашу конфигурацию в `prometheus.yml`
3. Примените заново: `kubectl apply -f prometheus-manual.yaml`
4. Перезагрузите конфигурацию Prometheus:
   ```bash
   kubectl exec -n monitoring deployment/prometheus -- \
     curl -X POST http://localhost:9090/-/reload
   ```

### Добавление правил алертов

Создайте ConfigMap с правилами:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  namespace: monitoring
data:
  artds.yml: |
    groups:
      - name: artds
        interval: 30s
        rules:
          - alert: HighLDAPConnections
            expr: ldap_connections_current > 1000
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Высокое количество LDAP подключений"
              description: "Под {{ $labels.kubernetes_pod_name }} имеет {{ $value }} подключений"
```

Смонтируйте в Deployment Prometheus:

```yaml
volumeMounts:
  - name: rules
    mountPath: /etc/prometheus/rules
    readOnly: true

volumes:
  - name: rules
    configMap:
      name: prometheus-rules
```

### Добавление Alertmanager

Разверните Alertmanager и настройте в Prometheus:

```yaml
# В prometheus.yml ConfigMap
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager.monitoring.svc:9093
```

## Открытие доступа к UI Prometheus

### Вариант 1: Port Forward (Разработка)

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

Доступ: http://localhost:9090

### Вариант 2: NodePort (Тестирование)

Отредактируйте Service в `prometheus-manual.yaml`:

```yaml
spec:
  type: NodePort
  ports:
    - name: web
      port: 9090
      targetPort: web
      nodePort: 30090  # Опционально: укажите порт
```

Доступ: http://NODE_IP:30090

### Вариант 3: LoadBalancer (Облако)

Отредактируйте Service:

```yaml
spec:
  type: LoadBalancer
```

Получите внешний IP:
```bash
kubectl get svc -n monitoring prometheus
```

### Вариант 4: Ingress (Production)

Раскомментируйте и настройте секцию Ingress в `prometheus-manual.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: prometheus-basic-auth
spec:
  rules:
    - host: prometheus.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prometheus
                port:
                  number: 9090
```

Создайте secret с basic auth:
```bash
htpasswd -c auth admin
kubectl create secret generic prometheus-basic-auth \
  --from-file=auth \
  -n monitoring
```

## Решение проблем

### Prometheus не обнаруживает поды artds

1. **Проверьте аннотации подов**:
   ```bash
   kubectl get pod -n artldap artds-0 -o yaml | grep -A5 annotations
   ```

   Должно показать:
   ```yaml
   prometheus.io/scrape: "true"
   prometheus.io/port: "9313"
   prometheus.io/path: "/metrics"
   ```

2. **Проверьте метод сбора метрик**:
   ```bash
   helm get values artds -n artldap | grep scrapingMethod
   ```

   Должно быть: `scrapingMethod: annotations`

3. **Проверьте логи Prometheus**:
   ```bash
   kubectl logs -n monitoring deployment/prometheus | grep kubernetes-pods
   ```

### Метрики недоступны

1. **Протестируйте эндпоинт метрик напрямую**:
   ```bash
   kubectl port-forward -n artldap artds-0 9313:9313
   curl http://localhost:9313/metrics | grep ldap_
   ```

2. **Проверьте логи контейнера exporter**:
   ```bash
   kubectl logs -n artldap artds-0 -c exporter
   ```

3. **Убедитесь, что контейнер exporter запущен**:
   ```bash
   kubectl get pod -n artldap artds-0 -o jsonpath='{.spec.containers[*].name}'
   ```

   Должно включать `exporter`.

### Prometheus Target Down

1. **Проверьте детали target** в UI Prometheus:
   - Перейдите в Status → Targets
   - Кликните на неудавшийся target
   - Просмотрите сообщение об ошибке

2. **Типичные проблемы**:
   - Network policies блокируют доступ
   - Контейнер Exporter не здоров
   - Неправильная конфигурация порта
   - Под не в состоянии Running

3. **Проверьте сетевое подключение**:
   ```bash
   # Из пода Prometheus
   kubectl exec -n monitoring deployment/prometheus -- \
     curl http://artds-0.artds-metrics.artldap.svc:9313/metrics
   ```

### Высокое использование памяти

Если Prometheus использует слишком много памяти:

1. **Уменьшите время хранения**:
   ```yaml
   args:
     - '--storage.tsdb.retention.time=7d'  # Уменьшите с 15d
   ```

2. **Уменьшите размер хранения**:
   ```yaml
   args:
     - '--storage.tsdb.retention.size=4GB'  # Уменьшите с 9GB
   ```

3. **Увеличьте интервал сбора метрик**:
   ```yaml
   global:
     scrape_interval: 60s  # Увеличьте с 30s
   ```

4. **Увеличьте лимиты ресурсов**:
   ```yaml
   resources:
     limits:
       memory: 4Gi  # Увеличьте с 2Gi
   ```

## Рекомендации для production

### Безопасность

1. **Включите аутентификацию** в UI Prometheus (Ingress с basic auth)
2. **Используйте RBAC** - Пример включает минимальные необходимые разрешения
3. **Network policies** - Ограничьте доступ к Prometheus и эндпоинтам метрик
4. **TLS шифрование** - Настройте Ingress с TLS сертификатами

### Высокая доступность

Для production HA Prometheus:

1. **Используйте StatefulSet** вместо Deployment
2. **Множественные реплики** с различными shards для сбора метрик
3. **Внешнее хранилище** (например, Thanos, Cortex) для долгосрочных метрик
4. **Federation** для мониторинга мультикластера

### Резервное копирование

Резервное копирование данных Prometheus:

```bash
# Создать backup
kubectl exec -n monitoring prometheus-0 -- \
  tar czf /tmp/prometheus-backup.tar.gz /prometheus

# Скопировать backup
kubectl cp monitoring/prometheus-0:/tmp/prometheus-backup.tar.gz \
  ./prometheus-backup.tar.gz
```

### Мониторинг Prometheus

Мониторьте сам Prometheus:

- **Self-scraping**: Включено в примере конфигурации (job `prometheus`)
- **Метрики ресурсов**: Мониторьте CPU, память, использование диска
- **Производительность запросов**: Проверяйте метрики длительности запросов
- **Метрики сбора**: Мониторьте `scrape_duration_seconds`, метрику `up`

## Дополнительные ресурсы

- [Документация Prometheus](https://prometheus.io/docs/)
- [Язык запросов PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Kubernetes Service Discovery](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
- [Руководство по мониторингу artds](../README.md#мониторинг-с-prometheus)
- [Values Helm Chart](../../artds/values.yaml)

## Поддержка

По вопросам связанным с:
- **мониторингом artds**: См. основной [kubernetes/README.md](../README.md)
- **конфигурацией Prometheus**: См. [документацию Prometheus](https://prometheus.io/docs/)
- **обнаружением Kubernetes**: См. [Kubernetes SD config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
