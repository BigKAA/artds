# 📊 Мониторинг с Prometheus

## Ключевые PromQL запросы

```promql
# Текущие подключения по подам
ldap_connections_current{namespace="artldap"}

# Rate операций поиска за 5 минут
rate(ldap_operations_total{operation="search"}[5m])

# Hit rate кэша записей
rate(ldap_backend_entry_cache_hits[5m]) / rate(ldap_backend_entry_cache_tries[5m])

# Количество записей в backend
ldap_entries_total{namespace="artldap"}
```

## Troubleshooting мониторинга

### Exporter не запускается

```bash
# Проверить логи
kubectl logs -n artldap artds-0 -c exporter

# Проверить конфигурацию
kubectl get cm -n artldap artds-exporter-config -o yaml

# Проверить секреты
kubectl get secret -n artldap artds-admin-secret -o yaml
```

### Prometheus не scrape-ит метрики

```bash
# Проверить ServiceMonitor
kubectl describe servicemonitor -n artldap artds-metrics

# Проверить labels на Service
kubectl get svc -n artldap artds-metrics --show-labels

# Проверить Prometheus логи
kubectl logs -n monitoring -l app=prometheus
```

### Метрики возвращают ошибки

```bash
# Подключиться к поду экспортера
kubectl exec -it -n artldap artds-0 -c exporter -- sh

# Проверить LDAP подключение
ldapsearch -x -H ldap://localhost:3389 -b "cn=monitor" -s base

# Проверить bind credentials
ldapsearch -x -H ldap://localhost:3389 \
  -D "cn=Directory Manager" -w "$BIND_PASSWORD" \
  -b "cn=monitor" -s base
```
