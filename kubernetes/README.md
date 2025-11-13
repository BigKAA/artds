# Развертывание 389ds в Kubernetes

Это руководство показывает развертывание кластера 389 Directory Server в Kubernetes с использованием манифестов. Материал является продолжением [docker.md](../docker.md) и демонстрирует эквиваленты Docker команд в Kubernetes.

---

## 📋 Содержание

- [Сравнение Docker vs Kubernetes](#сравнение-docker-vs-kubernetes)
- [Требования](#требования)
- [Проверка окружения](#проверка-окружения)
- [Архитектура решения](#архитектура-решения)
- [Развертывание: Шаг за шагом](#развертывание-шаг-за-шагом)
- [Подход A: Ручная инициализация](#подход-a-ручная-инициализация-аналог-dockermd)
- [Подход B: Автоматическая инициализация](#подход-b-автоматическая-инициализация-через-job)
- [Инициализация плагинов](#инициализация-плагинов-два-подхода)
- [Проверка работы кластера](#проверка-работы-кластера)
- [Troubleshooting](#troubleshooting)
- [Переход к Helm Chart](#переход-к-helm-chart)

---

## 🔄 Сравнение: Docker vs Kubernetes

### Сравнение команд

#### Docker

```bash
# Запуск контейнера
docker run -d -m 1024M -p 3389:3389 -p 3636:3636 \
    -e DS_SUFFIX_NAME="dc=test,dc=local" \
    -e DS_DM_PASSWORD="password" \
    -e DS_REINDEX=True \
    -v /var/ldap:/data \
    --name ds-test \
    389ds/dirsrv:3.1

# Просмотр логов
docker logs ds-test -f

# Выполнение команд внутри контейнера
docker exec -it ds-test \
    dsconf ldap://localhost:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

#### Kubernetes

```bash
# Развертывание манифестов
kubectl apply -f kubernetes/

# Просмотр логов
kubectl logs -n artldap artds-0 -f

# Выполнение команд внутри пода
kubectl exec -it -n artldap artds-0 -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

---

## 📦 Требования

### Kubernetes Кластер

- **Минимальная конфигурация**:
  - 1 Сontrol нода
  - **Минимум 2 worker ноды** для размещения подов на разных нодах кластера.
- **Версия Kubernetes**: 1.24+
- **kubectl**: Настроен и подключен к кластеру

---

## 🔍 Проверка окружения

Перед началом развертывания убедитесь, что кластер соответствует требованиям:

```bash
# Проверка нод (должно быть минимум 2 worker ноды)
kubectl get nodes

# Проверка StorageClass
kubectl get storageclass

# Проверка cert-manager
kubectl get pods -n cert-manager
kubectl get clusterissuer

# Проверка MetalLB (если используется)
kubectl get pods -n metallb
kubectl get ipaddresspool -n metallb
```

## 🚀 Развертывание: Шаг за шагом

### Установка приложения

По аналогии с запуском приложения в обыкновенных контейнерах, сначала запустим поды с контейнерами 389ds.

Создадим namespace:

```bash
kubectl create ns artldap
```

```txt
namespace/artldap created
```

Первоначальный пароль администратора кластера и пользователя для репликаций поместим в secret (файл `manifests/01-secrets.yaml`):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: artds-admin-secret
  labels:
    app: artds
    component: authentication
type: Opaque
data:
  # Base64 encoded passwords
  # Для демонстрации используется "password"
  # echo -n "password" | base64
  DS_DM_PASSWORD: cGFzc3dvcmQ=
  DS_REPL_PASSWORD: cGFzc3dvcmQ=
```

Добавим Secret в кластер:

```bash
kubectl -n artldap apply -f manifests/01-secrets.yaml
```

```txt
secret/artds-admin-secret created
```

Для создания сертификатов будем использовать cert-manager. Соответственно создадим `kind: Certificate` (файл `manifests/02-certificate.yaml`).

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: artds-tls
  labels:
    app: artds
    component: tls
spec:
  # Имя Secret, в котором будут сохранены сертификаты
  secretName: artds-tls-secret

  # Срок действия сертификата (1 год)
  duration: 8760h # 365 days

  # Обновление за 15 дней до истечения
  renewBefore: 360h # 15 days

  # Subject Alternative Names (DNS имена)
  # Мы должны заранее знать namespace, где будет размещен StatefulSet
  # Его имя. И имя headless service. Для того, что бы корректно 
  # написать эту секцию.
  dnsNames:
    - artds-0.artds-hl.artldap.svc.cluster.local
    - artds-1.artds-hl.artldap.svc.cluster.local
    - artds-hl.artldap.svc.cluster.local
    - artds.artldap.svc.cluster.local

  # Мне заранее известны IP адреса, которые будут выданы MetalLB сервисам
  # типа LoadBalancer
  ipAddresses:
    - 192.168.218.183
    - 192.168.218.184
    - 192.168.218.185

  # Формирование Subject сертификата.
  subject:
    organizations:
      - "LDAP Test Cluster"

  # Не является CA сертификатом
  isCA: false

  # Конфигурация приватного ключа
  privateKey:
    algorithm: RSA
    encoding: PKCS8
    size: 4096
    rotationPolicy: Always

  # Использование ключа
  usages:
    - server auth
    - client auth

  # Ссылка на ClusterIssuer для выдачи сертификата
  issuerRef:
    name: dev-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

Добавим манифест в кластер:

```bash
kubectl -n artldap apply -f manifests/02-certificate.yaml
```

```txt
certificate.cert-manager.io/artds-tls created
```

После создания Certificate, cert-manager автоматически создаст Secret
с именем `artds-tls-secret`, содержащий:

- tls.crt - сертификат
- tls.key - приватный ключ
- ca.crt  - корневой сертификат (если issuer предоставляет)

Этот Secret будет смонтирован в поды 389ds для использования LDAPS (порт 3636)

Проверим, был ли создан Secret.

```bash
kubectl -n artldap get secrets
```

```txt
NAME                 TYPE                DATA   AGE
artds-admin-secret   Opaque              2      44s
artds-tls-secret     kubernetes.io/tls   3      21s
```

Манифест StatefullSet (файл `manifests/03-statefulset.yaml`):

```yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: artds
  labels:
    app: artds
    component: directory-server
spec:
  # Имя headless service для DNS discovery
  serviceName: artds-hl

  # Количество реплик
  replicas: 2

  # Селектор подов
  selector:
    matchLabels:
      app: artds
      component: directory-server

  # Шаблон пода
  template:
    metadata:
      labels:
        app: artds
        component: directory-server
    spec:
      # ====================================================
      # Anti-affinity: принудительное размещение на разных worker нодах
      # ====================================================
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - artds
              # КРИТИЧНО: размещать поды на разных нодах
              topologyKey: kubernetes.io/hostname

      # ====================================================
      # Init Container проверяет номер пода.
      # Если это второй (считаем с 0) и более под,
      # возвращаем ошибку. Под не будет стартовать и
      # и будет постоянно перезагружаться.
      # ====================================================
      initContainers:
        - name: init-permissions
          image: busybox:1.37.0
          command: ['sh', '-c']
          args:
            - |
              NUM=$(echo $POD_NAME | cut -f2 -d'-')
              if [ $NUM -gt 1 ]; then
                echo "Number of replicas must be 1 or 2"
                exit 1
              fi
              # Установка прав доступа
              chmod 755 /data
              echo "Initialization completed"
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          volumeMounts:
            - name: data
              mountPath: /data

      # ====================================================
      # Основной контейнер 389ds
      # ====================================================
      containers:
        - name: dirsrv
          image: 389ds/dirsrv:3.1
          imagePullPolicy: IfNotPresent

          # Порты контейнера
          ports:
            - name: ldap
              containerPort: 3389
              protocol: TCP
            - name: ldaps
              containerPort: 3636
              protocol: TCP

          # Переменные окружения
          env:
            # Суффикс LDAP
            - name: DS_SUFFIX_NAME
              value: "dc=test,dc=local"

            # Пароль Directory Manager из Secret
            - name: DS_DM_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: artds-admin-secret
                  key: DS_DM_PASSWORD

            # Переиндексация при первом запуске
            - name: DS_REINDEX
              value: "True"

            # Уровень логирования (опционально)
            # - name: DS_ERRORLOG_LEVEL
            #   value: "266354688"

          # ====================================================
          # Volume Mounts
          # ====================================================
          volumeMounts:
            # Persistent data
            - name: data
              mountPath: /data

            # TLS сертификаты от cert-manager
            - name: tls-certs
              mountPath: /data/tls
              readOnly: true
            - name: dirsrv-tls-ca
              mountPath: '/data/tls/ca'
              readOnly: true

          # ====================================================
          # Health Checks
          # ====================================================
          livenessProbe:
            exec:
              command:
                - /usr/lib/dirsrv/dscontainer
                - -H
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          readinessProbe:
            exec:
              command:
                - /usr/lib/dirsrv/dscontainer
                - -H
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3

          # ====================================================
          # Resource Limits
          # ====================================================
          resources:
            requests:
              cpu: "1"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2048Mi"

      # ====================================================
      # Volumes
      # ====================================================
      volumes:
        # TLS сертификаты от cert-manager
        - name: tls-certs
          secret:
            secretName: artds-tls-secret
        
        # Сертификат CA необходимо монтировать в другую точку файловой
        # системы контейнера
        - name: dirsrv-tls-ca
          secret:
            secretName: artds-tls-secret
            items:
            - key: ca.crt
              path: ca.crt

  # ====================================================
  # VolumeClaimTemplates - автоматическое создание PVC для каждого пода
  # Эквивалент Docker: -v /var/ldap:/data
  # ====================================================
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app: artds
          component: storage
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: managed-nfs-storage
        resources:
          requests:
            storage: 1Gi
```

Применяем манифест:

```bash
kubectl -n artldap apply -f manifests/03-statefulset.yaml
```

```txt
statefulset.apps/artds created
```

Через некоторое время проверяем:

```bash
wtach kubectl -n artldap get all
```

Ждем когда запустятся оба пода:

```txt
NAME          READY   STATUS    RESTARTS   AGE
pod/artds-0   1/1     Running   0          20s
pod/artds-1   1/1     Running   0          30s

NAME                     READY   AGE
statefulset.apps/artds   0/2     30s
```

Смотрим логи подов:

```bash
kubectl -n artldap logs artds-0
kubectl -n artldap logs artds-1
```

Важно проверить отсутствие сообщения об ошибках и наличие строки `INFO: 389-ds-container started.`.

Создадим манифест с сервисами для доступа к кластеру (файл `manifests/04-services.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: artds
  labels:
    app: artds
    component: directory-server
  annotations:
    # MetalLB IP assignment из указанного диапазона
    metallb.io/loadBalancerIPs: 192.168.218.183
spec:
  type: LoadBalancer
  # Распределение трафика между всеми подами
  selector:
    app: artds
    component: directory-server

  # Порты для внешнего доступа
  ports:
    # LDAP (без шифрования)
    - name: ldap-tcp
      protocol: TCP
      port: 3389
      targetPort: 3389

    # LDAPS (с TLS шифрованием)
    - name: ldaps-tcp
      protocol: TCP
      port: 3636
      targetPort: 3636

---
# ====================================================
# Headless Service - для StatefulSet и репликации
# Предоставляет стабильные DNS имена для каждого пода
# ====================================================
apiVersion: v1
kind: Service
metadata:
  name: artds-hl
  labels:
    app: artds
    component: directory-server-headless
spec:
  # clusterIP: None делает service "headless"
  # Kubernetes не назначает ClusterIP, вместо этого
  # создает DNS записи для каждого пода
  clusterIP: None

  # Публикация всех подов в DNS, даже если они not ready
  publishNotReadyAddresses: true

  selector:
    app: artds
    component: directory-server

  ports:
    - name: ldap-tcp
      protocol: TCP
      port: 3389
      targetPort: 3389
    - name: ldaps-tcp
      protocol: TCP
      port: 3636
      targetPort: 3636

# DNS записи после создания:
#
# LoadBalancer Service (artds):
# - artds.artldap.svc.cluster.local
#   → Load balances to artds-0 and artds-1
#
# Headless Service (artds-hl):
# - artds-hl.artldap.svc.cluster.local
#   → Returns IPs of all pods
# - artds-0.artds-hl.artldap.svc.cluster.local
#   → Direct access to pod artds-0
# - artds-1.artds-hl.artldap.svc.cluster.local
#   → Direct access to pod artds-1

# ====================================================
# Опционально: Per-pod Services для debugging
# ====================================================
---
apiVersion: v1
kind: Service
metadata:
  name: artds-0
  labels:
    app: artds
    pod: artds-0
  annotations:
    metallb.io/loadBalancerIPs: 192.168.218.184
spec:
  type: LoadBalancer
  selector:
    app: artds
    component: directory-server
    statefulset.kubernetes.io/pod-name: artds-0
  ports:
    - name: ldap-tcp
      protocol: TCP
      port: 3389
      targetPort: 3389
    - name: ldaps-tcp
      protocol: TCP
      port: 3636
      targetPort: 3636
---
apiVersion: v1
kind: Service
metadata:
  name: artds-1
  labels:
    app: artds
    pod: artds-1
  annotations:
    metallb.io/loadBalancerIPs: 192.168.218.185
spec:
  type: LoadBalancer
  selector:
    app: artds
    component: directory-server
    statefulset.kubernetes.io/pod-name: artds-1
  ports:
    - name: ldap-tcp
      protocol: TCP
      port: 3389
      targetPort: 3389
    - name: ldaps-tcp
      protocol: TCP
      port: 3636
      targetPort: 3636
```

Применяем манифест:

```bash
kubectl -n artldap apply -f manifests/04-services.yaml
```

```txt
service/artds created
service/artds-hl created
service/artds-0 created
service/artds-1 created
```

Проверяем наличие сервисов:

```bash
kubectl -n artldap get svc
```

```txt
NAME       TYPE           CLUSTER-IP      EXTERNAL-IP       PORT(S)                         AGE
artds      LoadBalancer   10.233.20.134   192.168.218.183   3389:30350/TCP,3636:32650/TCP   4m10s
artds-0    LoadBalancer   10.233.35.246   192.168.218.184   3389:30595/TCP,3636:30663/TCP   4m10s
artds-1    LoadBalancer   10.233.16.189   192.168.218.185   3389:32024/TCP,3636:32611/TCP   4m10s
artds-hl   ClusterIP      None            <none>            3389/TCP,3636/TCP               4m10s
```

и `EndpointSlices`:

```bash
kubectl -n artldap get endpointslices
```

```txt
NAME             ADDRESSTYPE   PORTS       ENDPOINTS                    AGE
artds-0-sgbcs    IPv4          3389,3636   10.233.71.79                 4m43s
artds-1-hzr8w    IPv4          3389,3636   10.233.123.13                4m43s
artds-hl-q8dkr   IPv4          3389,3636   10.233.71.79,10.233.123.13   4m43s
artds-rns5s      IPv4          3389,3636   10.233.123.13,10.233.71.79   4m43s
```

---

## 🔧 Ручная инициализация (аналог docker.md)

Этот подход полностью повторяет команды из [docker.md](../docker.md), но адаптирован для Kubernetes.

### Шаг 1: Настройка формат логов

Настройка формата логов.

#### Access Log JSON

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging access set log-format json
```

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging access set log-format json
```

```txt
Successfully updated access log configuration
```

#### Error Log JSON

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging error set log-format json
```

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging error set log-format json
```

```txt
Successfully updated error log configuration
```

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging error set time-format "%Y-%m-%dT%H:%M:%S%z"
```

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging error set time-format "%Y-%m-%dT%H:%M:%S%z"
```

```txt
Successfully updated error log configuration
```

#### Audit Log JSON

Поддерживается начиная с версии 3.1.

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging audit set log-format json
```

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    logging audit set log-format json
```

```txt
Successfully updated audit log configuration
```

### Шаг 3: Проверка отсутствия backend

Сначала в первом поде:

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

Затем во втором:

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

Должны получить: `No backends`

### Шаг 3: Создание backend

На первом поде:

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend create --suffix "dc=test,dc=local" \
    --be-name userroot --create-suffix
```

Во втором поде:

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend create --suffix "dc=test,dc=local" \
    --be-name userroot --create-suffix
```

Ожидаемое сообщение: `The database was successfully created`

### Шаг 4: Включение репликации

На первом поде (replica-id=1):

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication enable \
    --suffix="dc=test,dc=local" \
    --role="supplier" \
    --replica-id=1 \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password"
```

На втором поде (replica-id=2):

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication enable \
    --suffix="dc=test,dc=local" \
    --role="supplier" \
    --replica-id=2 \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password"
```

Ожидаемое сообщение: `Replication successfully enabled for "dc=test,dc=local"`

### Шаг 5: Создание replication agreements

Agreement от artds-0 к artds-1:

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt create \
    --suffix="dc=test,dc=local" \
    --host="artds-1.artds-hl" \
    --port=3389 \
    --conn-protocol=LDAP \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password" \
    --bind-method=SIMPLE \
    meTo1
```

```txt
Successfully created replication agreement "meTo1"
```

Agreement от artds-1 к artds-0:

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt create \
    --suffix="dc=test,dc=local" \
    --host="artds-0.artds-hl" \
    --port=3389 \
    --conn-protocol=LDAP \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password" \
    --bind-method=SIMPLE \
    meTo0
```

```txt
Successfully created replication agreement "meTo0"
```

### Шаг 6: Инициализация репликации

⚠️ **Best Practice**: Инициализация ТОЛЬКО с artds-0 → artds-1

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt init meTo1 --suffix="dc=test,dc=local"
```

Ожидаемое сообщение: `Agreement initialization started...`

### Шаг 7: Проверка статуса репликации

В первом поде.

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt status --suffix "dc=test,dc=local" meTo1
```

Во втором поде.

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt status --suffix "dc=test,dc=local" meTo0
```

Ожидаемый статус на artds-1: `Replication Status: In Synchronization`

---

## 🤖 Подход B: Автоматическая инициализация через Job

Этот подход использует Kubernetes Job для полной автоматизации процесса инициализации.

### Преимущества
- Полная автоматизация
- Идемпотентность
- Повторяемость
- Отсутствие человеческого фактора

### Недостатки
- Сложнее debug
- Требует RBAC permissions
- Меньше контроля над процессом

### Применение

Job уже должен быть развернут (последний шаг развертывания):

```bash
kubectl apply -f 09-job-init.yaml
```

### Мониторинг выполнения

```bash
# Статус Job
kubectl get job -n artldap

# Логи в реальном времени
kubectl logs -n artldap job/artds-init -f

# Детальная информация
kubectl describe job artds-init -n artldap
```

### Повторный запуск Job

Если нужно перезапустить инициализацию:

```bash
# Удаление существующего Job
kubectl delete job artds-init -n artldap

# Применение заново
kubectl apply -f 09-job-init.yaml
```

### Что делает Job автоматически

1. ✅ Ожидание готовности подов (max 180 секунд)
2. ✅ Создание backends на artds-0 и artds-1
3. ✅ Включение репликации на обоих подах
4. ✅ Создание replication agreements (meTo1, meTo0)
5. ✅ Инициализация репликации (только artds-0 → artds-1)
6. ✅ Применение LDIF конфигурации (структура дерева)
7. ✅ Включение плагинов (Retro Changelog, MemberOf)
8. ✅ Рестарт подов (если плагины были изменены)

---

## 🔌 Инициализация плагинов: Два подхода

### Плагины для включения

1. **Retro Changelog**: Сохраняет все изменения в дереве LDAP
   - ⚠️ Не рекомендуется для production (нагрузка и размер БД)
   - Полезно для тестирования репликации

2. **MemberOf**: Автоматическое отслеживание членства в группах
   - Атрибут `memberOf` добавляется автоматически к пользователям
   - Упрощает проверку принадлежности к группам

### Подход A: Ручное включение

**Преимущества**: Полный контроль, простота понимания
**Недостатки**: Ручные операции на каждом поде, требует рестарта

#### Шаг 1: Включение плагинов на artds-0

```bash
kubectl exec -it -n artldap artds-0 -- bash -c "cat > /tmp/plugins.ldif << 'EOF'
dn: cn=Retro Changelog Plugin,cn=plugins,cn=config
changetype: modify
replace: nsslapd-pluginEnabled
nsslapd-pluginEnabled: on
-

dn: cn=MemberOf Plugin,cn=plugins,cn=config
changetype: modify
replace: nsslapd-pluginEnabled
nsslapd-pluginEnabled: on
-
replace: memberofgroupattr
memberofgroupattr: uniqueMember
EOF
"

kubectl exec -it -n artldap artds-0 -- \
    ldapmodify -H ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /tmp/plugins.ldif
```

#### Шаг 2: Включение плагинов на artds-1

```bash
kubectl exec -it -n artldap artds-1 -- bash -c "cat > /tmp/plugins.ldif << 'EOF'
dn: cn=Retro Changelog Plugin,cn=plugins,cn=config
changetype: modify
replace: nsslapd-pluginEnabled
nsslapd-pluginEnabled: on
-

dn: cn=MemberOf Plugin,cn=plugins,cn=config
changetype: modify
replace: nsslapd-pluginEnabled
nsslapd-pluginEnabled: on
-
replace: memberofgroupattr
memberofgroupattr: uniqueMember
EOF
"

kubectl exec -it -n artldap artds-1 -- \
    ldapmodify -H ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /tmp/plugins.ldif
```

#### Шаг 3: Рестарт подов

```bash
# Рестарт StatefulSet (rolling restart)
kubectl rollout restart statefulset artds -n artldap

# Ожидание завершения рестарта
kubectl rollout status statefulset artds -n artldap

# Проверка подов
kubectl get pods -n artldap
```

#### Шаг 4: Проверка включения плагинов

```bash
kubectl exec -it -n artldap artds-0 -- \
    ldapsearch -H ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "cn=plugins,cn=config" cn="MemberOf Plugin" \
    | grep "nsslapd-pluginEnabled: on"
```

### Подход B: Автоматическое включение (через Job)

**Преимущества**: Полная автоматизация, идемпотентность
**Недостатки**: Требует RBAC, сложнее debug

Job автоматически:
1. Проверяет статус плагинов на каждом поде
2. Включает плагины если они выключены
3. Патчит StatefulSet для триггера рестарта (через Kubernetes API)
4. Логирует все операции в JSON формате

Включение плагинов происходит автоматически при запуске Job:
```bash
kubectl apply -f 09-job-init.yaml
kubectl logs -n artldap job/artds-init -f
```

---

## ✅ Проверка работы кластера

### 1. Проверка статуса подов

```bash
# Все поды должны быть Running и Ready
kubectl get pods -n artldap

# Детальная информация
kubectl describe pod artds-0 -n artldap
kubectl describe pod artds-1 -n artldap
```

### 2. Проверка репликации

```bash
# Статус репликации на artds-0
kubectl exec -it -n artldap artds-0 -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication status --suffix "dc=test,dc=local"

# Статус репликации на artds-1
kubectl exec -it -n artldap artds-1 -- \
    dsconf ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication status --suffix "dc=test,dc=local"
```

Ожидаемый вывод: `Replication Status: In Synchronization`

### 3. Тест репликации данных

Добавим тестовую запись на artds-0:
```bash
kubectl exec -it -n artldap artds-0 -- bash -c "cat > /tmp/test-user.ldif << 'EOF'
dn: uid=testuser,ou=People,dc=test,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: top
cn: Test User
sn: User
uid: testuser
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/testuser
loginShell: /bin/bash
EOF
"

kubectl exec -it -n artldap artds-0 -- \
    ldapadd -H ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /tmp/test-user.ldif
```

Проверим наличие на artds-1:
```bash
kubectl exec -it -n artldap artds-1 -- \
    ldapsearch -H ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "dc=test,dc=local" "(uid=testuser)"
```

Если пользователь найден на artds-1 - репликация работает! ✅

### 4. Просмотр JSON логов

Проект использует JSON-формат для всех логов 389ds (Access, Error, Audit). Просмотр логов:

```bash
# Просмотр JSON логов пода artds-0
kubectl logs -n artldap artds-0 -f | jq .

# Просмотр только Error уровня
kubectl logs -n artldap artds-0 | jq 'select(.level == "ERROR")'

# Фильтрация Access Log по пользователю
kubectl logs -n artldap artds-0 | jq 'select(.bind_dn | contains("uid=testuser"))'

# Просмотр последних 50 записей с форматированием
kubectl logs -n artldap artds-0 --tail=50 | jq .
```

### 5. Проверка внешнего доступа

Получение IP LoadBalancer:
```bash
kubectl get svc artds -n artldap
```

Тест подключения (с вашей локальной машины):
```bash
# Замените <EXTERNAL-IP> на IP из предыдущей команды
ldapsearch -H ldap://<EXTERNAL-IP>:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "dc=test,dc=local" "(objectClass=*)"
```

### 5. Проверка TLS/LDAPS

```bash
# Тест LDAPS подключения
kubectl exec -it -n artldap artds-0 -- \
    ldapsearch -H ldaps://artds-0.artds-hl:3636 \
    -D 'cn=Directory Manager' -w "password" \
    -b "dc=test,dc=local" "(objectClass=*)"
```

---

## 🔧 Troubleshooting

### Поды не запускаются

**Симптом**: Pod в состоянии `Pending` или `CrashLoopBackOff`

**Диагностика**:
```bash
kubectl describe pod artds-0 -n artldap
kubectl logs -n artldap artds-0 --previous
```

**Возможные причины**:
1. **Insufficient resources**:
   - Worker ноды не имеют достаточно CPU/памяти
   - Решение: Увеличить ресурсы нод или уменьшить requests в StatefulSet

2. **PVC не создается**:
   ```bash
   kubectl get pvc -n artldap
   kubectl describe pvc artds-data-artds-0 -n artldap
   ```
   - Проверить наличие StorageClass
   - Проверить provisioner работает

3. **Anti-affinity конфликт**:
   - Только одна worker нода доступна
   - Решение: Добавить worker ноды или временно удалить anti-affinity

### Репликация не работает

**Симптом**: Данные не реплицируются между подами

**Диагностика**:
```bash
# Проверка agreement статуса
kubectl exec -it -n artldap artds-0 -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt status --suffix "dc=test,dc=local" meTo1
```

**Возможные причины**:
1. **Сетевая связность**:
   - Поды не могут достучаться друг до друга
   - Проверить: `kubectl exec -it -n artldap artds-0 -- ping artds-1.artds-hl`

2. **Неверные credentials**:
   - Пароль репликации неправильный
   - Проверить Secret: `kubectl get secret artds-admin-secret -n artldap -o yaml`

---

## 📝 JSON Logging Integration

Начиная с этапа развертывания, кластер 389ds автоматически настроен для использования JSON-формата логирования. Это упрощает интеграцию с современными системами мониторинга и анализа логов.

### Формат логов

Все логи 389ds (Access, Error, Audit) конфигурируются в JSON-формате с ISO 8601 timestamp:

```json
{
  "date": "2025-11-12 14:23:45+0000",
  "utc_time": "2025-11-12T14:23:45.123456+00:00",
  "level": "INFO",
  "operation": "BIND",
  "bind_dn": "uid=testuser,ou=People,dc=test,dc=local",
  "client_ip": "192.168.1.100",
  "conn_id": 123,
  "op_id": 1,
  "result": 0,
  "etime": 0.001234
}
```

### Конфигурация в ConfigMap

JSON логирование настраивается автоматически init-job через ConfigMap ([05-configmap-init.yaml:209-246](kubernetes/05-configmap-init.yaml#L209-L246)):

```bash
# Для каждого пода настраивается:
dsconf logging access set log-format json
dsconf logging access set time-format "%Y-%m-%dT%H:%M:%S%z"
dsconf logging error set log-format json
dsconf logging error set time-format "%Y-%m-%dT%H:%M:%S%z"
dsconf logging audit set log-format json  # Requires 389ds 3.1.1+
```

### Просмотр и анализ логов

#### Базовый просмотр

```bash
# Просмотр всех логов с форматированием
kubectl logs -n artldap artds-0 -f | jq .

# Только последние 100 записей
kubectl logs -n artldap artds-0 --tail=100 | jq .

# Логи всех подов одновременно
kubectl logs -n artldap -l app.kubernetes.io/name=artds -f | jq .
```

#### Фильтрация логов

```bash
# Только ошибки (Error level)
kubectl logs -n artldap artds-0 | jq 'select(.level == "ERROR")'

# Операции конкретного пользователя
kubectl logs -n artldap artds-0 | jq 'select(.bind_dn | contains("uid=testuser"))'

# BIND операции
kubectl logs -n artldap artds-0 | jq 'select(.operation == "BIND")'

# Медленные запросы (etime > 1 секунда)
kubectl logs -n artldap artds-0 | jq 'select(.etime > 1.0)'

# Ошибки аутентификации (result != 0)
kubectl logs -n artldap artds-0 | jq 'select(.operation == "BIND" and .result != 0)'
```

#### Статистика и аналитика

```bash
# Топ-10 пользователей по количеству операций
kubectl logs -n artldap artds-0 --tail=10000 | \
  jq -r '.bind_dn' | sort | uniq -c | sort -rn | head -10

# Средняя скорость выполнения операций
kubectl logs -n artldap artds-0 --tail=1000 | \
  jq -s 'map(.etime) | add/length'

# Количество операций по типам
kubectl logs -n artldap artds-0 --tail=5000 | \
  jq -r '.operation' | sort | uniq -c | sort -rn
```

### Интеграция с системами логирования

#### FluentBit Integration

Проект включает пример конфигурации FluentBit DaemonSet для сбора и пересылки логов. См. [kubernetes/examples/fluentbit-json-logs.yaml](kubernetes/examples/fluentbit-json-logs.yaml).

**Развертывание FluentBit:**

```bash
# Развернуть FluentBit DaemonSet
kubectl apply -f kubernetes/examples/fluentbit-json-logs.yaml

# Проверить статус
kubectl get pods -n logging
kubectl logs -n logging -l app=fluent-bit -f
```

**Возможности:**
- Автоматический сбор логов всех `artds-*` подов
- Парсинг JSON формата 389ds
- Обогащение метаданными Kubernetes (pod, namespace, labels)
- Вывод в stdout (можно настроить пересылку в Loki, Elasticsearch, CloudWatch)

#### Prometheus/Loki Stack

```yaml
# Promtail config snippet для сбора JSON логов
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
          client_ip: client_ip
    - labels:
        level:
        operation:
```

#### ELK Stack Integration

```yaml
# Filebeat config для Kubernetes
filebeat.inputs:
  - type: container
    paths:
      - /var/log/containers/artds-*.log
    json.keys_under_root: true
    json.add_error_key: true
    processors:
      - add_kubernetes_metadata:
          host: ${NODE_NAME}
          matchers:
            - logs_path:
                logs_path: "/var/log/containers/"
```

### Откат на стандартный формат

Если необходимо вернуться к текстовому формату, отредактируйте [05-configmap-init.yaml](kubernetes/05-configmap-init.yaml):

```bash
# Закомментируйте секцию JSON LOGGING CONFIGURATION (строки 209-246)
# Или измените log-format на 'default':
dsconf logging access set log-format default
dsconf logging error set log-format default
```

Затем пересоздайте ConfigMap и перезапустите init-job:

```bash
kubectl delete configmap artds-init -n artldap
kubectl apply -f kubernetes/05-configmap-init.yaml
kubectl delete job artds-init -n artldap
kubectl apply -f kubernetes/09-job-init.yaml
```

3. **Backend не создан**:
   - Проверить: `dsconf ... backend suffix list`

### Job инициализации падает

**Симптом**: Job в состоянии `Failed` или `Error`

**Диагностика**:
```bash
kubectl logs -n artldap job/artds-init
kubectl describe job artds-init -n artldap
```

**Возможные причины**:
1. **RBAC permissions**:
   - ServiceAccount не имеет прав
   - Проверить: `kubectl auth can-i patch statefulsets --as=system:serviceaccount:artldap:artds-init-sa -n artldap`

2. **Timeout waiting for pods**:
   - Поды StatefulSet не стали Ready за 180 секунд
   - Увеличить `initialWaitSeconds` в ConfigMap

3. **Backend уже существует**:
   - Повторный запуск Job после успешной инициализации
   - Это нормально, скрипт пропускает существующие backends

### Certificate не выдается

**Симптом**: Certificate в состоянии `False` или `Pending`

**Диагностика**:
```bash
kubectl get certificate artds-tls -n artldap
kubectl describe certificate artds-tls -n artldap
kubectl get certificaterequest -n artldap
```

**Возможные причины**:
1. **ClusterIssuer не существует**:
   ```bash
   kubectl get clusterissuer dev-ca-issuer
   ```

2. **cert-manager не работает**:
   ```bash
   kubectl get pods -n cert-manager
   ```

3. **Неверная конфигурация Certificate**:
   - Проверить DNS names, issuerRef

### LoadBalancer Service не получает External IP

**Симптом**: Service artds в состоянии `<pending>` для EXTERNAL-IP

**Диагностика**:
```bash
kubectl get svc artds -n artldap
kubectl describe svc artds -n artldap
```

**Возможные причины**:
1. **MetalLB не установлен**:
   ```bash
   kubectl get pods -n metallb
   ```

2. **IP range не сконфигурирован**:
   ```bash
   kubectl get ipaddresspool -n metallb
   ```

3. **IP уже используется**:
   - Указанный IP (192.168.218.183) занят другим сервисом

### Плагины не включаются

**Симптом**: После применения ldapmodify плагины остаются выключены

**Диагностика**:
```bash
kubectl exec -it -n artldap artds-0 -- \
    ldapsearch -H ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "cn=plugins,cn=config" cn="MemberOf Plugin"
```

**Решение**:
- Плагины требуют рестарта сервера после включения
- Выполнить: `kubectl rollout restart statefulset artds -n artldap`

---

## 🎓 Переход к Helm Chart

### Проблемы текущего подхода

1. **Дублирование конфигурации**:
   - Один и тот же суффикс `dc=test,dc=local` повторяется в 5+ файлах
   - Пароли дублируются в Secret и переменных окружения
   - IP адреса LoadBalancer hardcoded в манифестах

2. **Сложность управления параметрами**:
   - Для изменения одного параметра нужно редактировать несколько файлов
   - Нет централизованной конфигурации
   - Легко допустить ошибку и создать несоответствия

3. **Отсутствие версионирования**:
   - Нет четкой версии "конфигурации кластера"
   - Сложно откатиться к предыдущему состоянию
   - Нет истории изменений

4. **Нет переиспользования**:
   - Каждый раз копируем и редактируем манифесты
   - Сложно поддерживать несколько окружений (dev, test, prod)
   - Нет шаблонизации для разных конфигураций

5. **Управление namespace**:
   - В plain Kubernetes нужен отдельный манифест `01-namespace.yaml`
   - При смене namespace нужно редактировать все манифесты с hardcoded namespace
   - В Helm namespace указывается при установке: `helm install -n <namespace> --create-namespace`

### Как Helm решает эти проблемы

```yaml
# values.yaml (единый источник конфигурации)
replicaCount: 2
image:
  repository: 389ds/dirsrv
  tag: "3.1"

ds:
  suffix: "dc=test,dc=local"
  adminPassword: "password"
  replPassword: "password"

services:
  main:
    type: LoadBalancer
    annotations:
      metallb.io/loadBalancerIPs: 192.168.218.183
```

**Преимущества**:
- ✅ Параметры в одном месте (`values.yaml`)
- ✅ Версионирование через Chart.yaml
- ✅ Переиспользование через templates
- ✅ Управление релизами (install, upgrade, rollback)
- ✅ Поддержка multiple environments
- ✅ Встроенное тестирование (`helm lint`, `helm test`)

### Следующий этап

Перейдите к изучению [../artds/README.md](../artds/README.md) для:
1. Понимания как преобразовать манифесты в Helm templates
2. Изучения best practices Helm chart разработки
3. Production-ready конфигурации с hooks и helpers
4. Автоматизации через ArgoCD GitOps

---

## 📊 Мониторинг с Prometheus

### Архитектура мониторинга

```
┌─────────────────────────────────────────────────────┐
│  Namespace: artldap                                 │
│                                                     │
│  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │ Pod: artds-0        │  │ Pod: artds-1        │  │
│  │                     │  │                     │  │
│  │ ┌─────────────┐     │  │ ┌─────────────┐     │  │
│  │ │ dirsrv      │     │  │ │ dirsrv      │     │  │
│  │ │ :3389       │     │  │ │ :3389       │     │  │
│  │ └─────────────┘     │  │ └─────────────┘     │  │
│  │         │           │  │         │           │  │
│  │         │ localhost │  │         │ localhost │  │
│  │         ▼           │  │         ▼           │  │
│  │ ┌─────────────┐     │  │ ┌─────────────┐     │  │
│  │ │ exporter    │     │  │ │ exporter    │     │  │
│  │ │ :9313       │     │  │ │ :9313       │     │  │
│  │ └──────┬──────┘     │  │ └──────┬──────┘     │  │
│  └────────┼────────────┘  └────────┼────────────┘  │
│           │                        │               │
│           └────────┬───────────────┘               │
│                    │                               │
│           ┌────────▼────────┐                      │
│           │ Service: artds- │                      │
│           │ metrics (9313)  │                      │
│           └────────┬────────┘                      │
│                    │                               │
│           ┌────────▼────────────┐                  │
│           │ ServiceMonitor      │                  │
│           │ (artds-metrics)     │                  │
│           └────────┬────────────┘                  │
└────────────────────┼───────────────────────────────┘
                     │
         ┌───────────▼────────────┐
         │ Namespace: monitoring  │
         │                        │
         │  ┌──────────────────┐  │
         │  │ Prometheus       │  │
         │  │ Operator         │  │
         │  └────────┬─────────┘  │
         │           │            │
         │           ▼            │
         │  ┌──────────────────┐  │
         │  │ Grafana          │  │
         │  │ :3000            │  │
         │  └──────────────────┘  │
         └────────────────────────┘
```

### Деплой мониторинга

#### Вариант 1: С Prometheus Operator

```bash
# 1. Применить манифесты с экспортером
kubectl apply -f kubernetes/12-configmap-exporter.yaml
kubectl apply -f kubernetes/07-statefulset.yaml
kubectl apply -f kubernetes/13-service-metrics.yaml
kubectl apply -f kubernetes/14-servicemonitor.yaml

# 2. Проверить статус
kubectl get pods -n artldap
kubectl logs -n artldap artds-0 -c exporter

# 3. Проверить метрики напрямую
kubectl port-forward -n artldap artds-0 9313:9313
curl http://localhost:9313/metrics | grep ldap_
```

#### Вариант 2: Ручная конфигурация Prometheus

Если Prometheus Operator не установлен, используйте manual конфигурацию:

```bash
# 1. Создать namespace для мониторинга
kubectl create namespace monitoring

# 2. Деплой Prometheus (пример в kubernetes/examples/prometheus-manual.yaml)
kubectl apply -f kubernetes/examples/prometheus-manual.yaml

# 3. Получить LoadBalancer IP
kubectl get svc -n monitoring prometheus

# 4. Открыть Prometheus UI
# http://<PROMETHEUS_IP>:9090
```

### Проверка метрик

#### Проверить доступность endpoints

```bash
# Проверить Service
kubectl get svc -n artldap artds-metrics
kubectl get endpoints -n artldap artds-metrics

# Должно показать оба пода:
# artds-0.artds-metrics.artldap.svc.cluster.local:9313
# artds-1.artds-metrics.artldap.svc.cluster.local:9313
```

#### Проверить ServiceMonitor

```bash
kubectl get servicemonitor -n artldap artds-metrics -o yaml
```

#### Проверить в Prometheus

```bash
# Port-forward к Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Открыть UI: http://localhost:9090
# Проверить targets: Status → Targets → 389ds-artldap
```

### Ключевые PromQL запросы

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

### Troubleshooting мониторинга

#### Exporter не запускается

```bash
# Проверить логи
kubectl logs -n artldap artds-0 -c exporter

# Проверить конфигурацию
kubectl get cm -n artldap artds-exporter-config -o yaml

# Проверить секреты
kubectl get secret -n artldap artds-admin-secret -o yaml
```

#### Prometheus не scrape-ит метрики

```bash
# Проверить ServiceMonitor
kubectl describe servicemonitor -n artldap artds-metrics

# Проверить labels на Service
kubectl get svc -n artldap artds-metrics --show-labels

# Проверить Prometheus логи
kubectl logs -n monitoring -l app=prometheus
```

#### Метрики возвращают ошибки

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

---

## 📚 Дополнительные материалы

### Kubernetes Concepts
- [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Services](https://kubernetes.io/docs/concepts/services-networking/service/)
- [PersistentVolumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

### 389ds Documentation
- [Multi-Supplier Replication](https://www.port389.org/docs/389ds/howto/howto-multisupplierreplication.html)
- [Plugin Configuration](https://www.port389.org/docs/389ds/design/plugins.html)

### cert-manager
- [Documentation](https://cert-manager.io/docs/)

---

**Статус**: Готово к использованию
**Версия**: 1.0
**Последнее обновление**: 2025-01-12
