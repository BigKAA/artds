# Развертывание 389ds в Kubernetes

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
  - **1 Сontrol нода.**
  - **Минимум 2 worker ноды** для размещения подов на разных нодах кластера.
- **Версия Kubernetes**: 1.24+
- **kubectl**: Настроен и подключен к кластеру
- Установлен cert-manager.
  - Добавлен cluster-issuer: `dev-ca-issuer`
- Установлен MetalLB или другой контроллер для реализации сервисов типа `LoadBalancer`.

[Пример установки минимального набора приложений](https://github.com/BigKAA/youtube/tree/master/1.31) в kubernetes.

---

## 🔍 Проверка окружения

Перед началом развертывания убедитесь, что кластер соответствует требованиям:

```bash
# Проверка нод (должно быть минимум 2 worker ноды)
kubectl get nodes

# Проверка StorageClass
kubectl get storageclass

# Проверка cert-manager
kubectl -n cert-manager get pods
kubectl get clusterissuer

# Проверка MetalLB (если используется)
kubectl -n metallb get pods
kubectl -n metallb get ipaddresspool
```

---

## 🚀 Развертывание

### Установка приложения

По аналогии с запуском приложения в обыкновенных контейнерах, сначала запустим поды с контейнерами 389ds.

#### Namespace

Создадим namespace:

```bash
kubectl create ns artldap
```

```txt
namespace/artldap created
```

#### Secret с паролями

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

#### Certificate

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

  # Мне заранее известны IP адреса, которые будут выданы MetalLB сервисам типа LoadBalancer.
  # Измените на адреса актуальные для вашего пула адресов.
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

#### StatefullSet 389ds

Манифест `StatefullSet` (файл `manifests/03-statefulset.yaml`):

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
            
            - name: DS_REPL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: artds-admin-secret
                  key: DS_REPL_PASSWORD

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
watch kubectl -n artldap get all
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

#### Services

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

### Настройка формат логов

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

### Проверка отсутствия backend

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

### Создание backend

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

### Включение репликации

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

### Создание replication agreements

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

### Инициализация репликации

⚠️ Инициализация ТОЛЬКО с artds-0 → artds-1

```bash
kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    dsconf ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt init meTo1 --suffix="dc=test,dc=local"
```

Ожидаемое сообщение: `Agreement initialization started...`

### Проверка статуса репликации

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

## 🤖 Автоматическая инициализация через Job

Конечно, можно конфигурировать LDAP кластер "вручную", как в предыдущем примере. Для упрощения, можно написать shell script, автоматизирующий этот процесс. Но мы используем kubernetes. А это значит, что максимум что мы должны делать - это каким либо образом поместить манифесты в кластер kubernetes. А дальше k8s должен развернуть приложение, согласно наших пожеланий в манифестах.

Чаcть манифестов мы написали на предыдущем шаге. Осталось добавть `Job`, задача которого - произвести конфигурацию кластера 389ds. И добавить используемы в `Job` файлы в `СonfigMaps`.

Сам по себе `Job` - это манифест, который позволит запустить какое то приложение. Мы будем сами создавать это приложение. Писать будем на "админском" языке программирования: shell script.

Для удобства чтения скрипта он вынесен в отдельный файл [job-script.sh](job-script.sh).

Контейнер, используемый в `Job` - это контейнер 389ds (`389ds/dirsrv:3.1`). Он содержит все необходимые инструменты для работы с LDAP сервером.

Мы не будем подробно разбирать этот скрипт. Просто обозначим основные действия, которые он выполняет.

- Проверка количества подов. Если это 3-й и более под, конфигурация пода не происходит и он не подключается к текущему кластеру LDAP.
- Настройка формата логов.
- Инициализация backend.
- Инициализация репликации.
- Заполнение дерева LDAP начальными элементами. (Если эти данные есть в отдельном ConfigMap)
- Включение и настройка плагинов и рестарт подов.

### Прежде чем продолжить

Если вы установили и сконфигурировали приложение в ручном режиме, сначала удалите установленное приложение.

```bash
kubectl delete ns artldap
```

Дождитесь удаления namespace. И создайте его снова.

```bash
kubectl create ns artldap
```

Установите приложение:

```bash
kubectl -n artldap apply -f manifests
```

Конфигурация LDAP серверов, как говорилось ранее, будет производиться скриптом в `Job`.

### Job RBAC

Поскольку скрипт будет обращаться к kubernetes API для обновления (patch) манифестов. Необходимо настроить правида RBAC. (Файл [manifests-auto/05-rbac.yaml](manifests-auto/05-rbac.yaml))

`Job` будет запускаться исползую следующий `ServiceAccount`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: artds-init-sa
  labels:
    app: artds
    component: initialization
```

`Role`, разрешающая доступы к Kubernetes API:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: artds-init-role
  labels:
    app: artds
    component: initialization
rules:
  # Разрешение на чтение StatefulSet
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["get", "list"]

  # Разрешение на изменение (patch) StatefulSet
  # Используется для рестарта подов через аннотацию
  - apiGroups: ["apps"]
    resources: ["statefulsets"]
    verbs: ["patch"]

  # Опционально: разрешение на чтение подов
  # Может быть полезно для проверки статуса
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
```

И `RoleBinding`, связывающий `Role` и `ServiceAccount`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: artds-init-rolebinding
  labels:
    app: artds
    component: initialization
subjects:
  # ServiceAccount, которому предоставляются права
  - kind: ServiceAccount
    name: artds-init-sa
    namespace: artldap
roleRef:
  # Role, права которой предоставляются
  kind: Role
  name: artds-init-role
  apiGroup: rbac.authorization.k8s.io
```

Применим манифест:

```bash
kubectl -n artldap apply -f manifests-auto/05-rbac.yaml
```

```txt
serviceaccount/artds-init-sa created
role.rbac.authorization.k8s.io/artds-init-role created
rolebinding.rbac.authorization.k8s.io/artds-init-rolebinding created
```

### Job ConfigMaps

#### Init script

В файле [manifests-auto/06-configmap-init.yaml](manifests-auto/06-configmap-init.yaml) находится `ConfigMap` с написанным нами скриптом.

Применим этот манифест:

```bash
kubectl -n artldap apply -f manifests-auto/06-configmap-init.yaml
```

```txt
configmap/artds-init-script created
```

#### LDIF файлы с конфигурацией

Конфигурация дерева LDAP будет в отдельном `ConfigMap`: файл [manifests-auto/07-configmap-infra.yaml](manifests-auto/07-configmap-infra.yaml). Файлы, находящиеся в этом файле используются в скрипте инициализации LDAP сервера.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: artds-infra-ldif
  namespace: artldap
  labels:
    app: artds
    component: ldap-structure
data:
  # =================================================================
  # Модификация корневого суффикса для добавления ACI
  # Эквивалент: ldapmodify -c -f /var/ldap/initConfigModify.ldif
  # =================================================================
  init-config-modify.ldif: |
    dn: dc=test,dc=local
    changetype: modify
    add: aci
    aci: (targetattr ="*")(version 3.0;acl "Directory Administrators Group";allow (all) (groupdn = "ldap:///cn=Directory Administrators,dc=test,dc=local");)
    -
    add: aci
    aci: (targetattr="ou || objectClass")(targetfilter="(objectClass=organizationalUnit)")(version 3.0; acl "Enable anyone ou read"; allow (read, search, compare)(userdn="ldap:///anyone");)

  # =================================================================
  # Создание базовой структуры LDAP дерева
  # Эквивалент: ldapadd -c -f /var/ldap/init-config.ldiff
  # =================================================================
  init-config.ldif: |
    # Organizational Unit: Groups
    dn: ou=Groups,dc=test,dc=local
    objectClass: organizationalunit
    objectClass: top
    ou: Groups
    aci: (targetattr="cn || member || gidNumber || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_admin to manage groups"; allow (write, add, delete)(groupdn="ldap:///cn=group_admin,ou=permissions,dc=test,dc=local");)
    aci: (targetattr="cn || member || memberUid || gidNumber || nsUniqueId || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable anyone group read"; allow (read, search, compare)(userdn="ldap:///anyone");)
    aci: (targetattr="member")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_modify to alter members"; allow (write)(groupdn="ldap:///cn=group_modify,ou=permissions,dc=test,dc=local");)

    # Organizational Unit: People
    dn: ou=People,dc=test,dc=local
    objectClass: organizationalunit
    objectClass: top
    ou: People
    aci: (targetattr="displayName || legalName || userPassword || nsSshPublicKey")(version 3.0; acl "Enable self partial modify"; allow (write)(userdn="ldap:///self");)
    aci: (targetattr="legalName || telephoneNumber || mobile || sn")(targetfilter="(|(objectClass=nsPerson)(objectClass=inetOrgPerson))")(version 3.0; acl "Enable self legalname read"; allow (read, search, compare)(userdn="ldap:///self");)
    aci: (targetattr="legalName || telephoneNumber")(targetfilter="(objectClass=nsPerson)")(version 3.0; acl "Enable user legalname read"; allow (read, search, compare)(groupdn="ldap:///cn=user_private_read,ou=permissions,dc=test,dc=local");)
    aci: (targetattr="objectClass || description || nsUniqueId || uid || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || nsSshPublicKey || nsAccountLock || userCertificate")(targetfilter="(objectClass=posixaccount)")(version 3.0; acl "Enable anyone user read"; allow (read, search, compare)(userdn="ldap:///anyone");)
    aci: (targetattr="uid || description || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || legalName || telephoneNumber || mobile")(targetfilter="(&(objectClass=nsPerson)(objectClass=nsAccount))")(version 3.0; acl "Enable user admin create"; allow (write, add, delete, read)(groupdn="ldap:///cn=user_admin,ou=permissions,dc=test,dc=local");)
    aci: (targetattr="uid || description || displayName || loginShell || uidNumber || gidNumber || gecos || homeDirectory || cn || memberOf || mail || legalName || telephoneNumber || mobile")(targetfilter="(&(objectClass=nsPerson)(objectClass=nsAccount))")(version 3.0; acl "Enable user modify to change users"; allow (write, read)(groupdn="ldap:///cn=user_modify,ou=permissions,dc=test,dc=local");)
    aci: (targetattr="userPassword || nsAccountLock || userCertificate || nsSshPublicKey")(targetfilter="(objectClass=nsAccount)")(version 3.0; acl "Enable user password reset"; allow (write, read)(groupdn="ldap:///cn=user_passwd_reset,ou=permissions,dc=test,dc=local");)

    # Directory Administrators Group
    dn: cn=Directory Administrators,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: Directory Administrators

    # Organizational Unit: Dismissed Users
    dn: ou=Dismissed,dc=test,dc=local
    objectClass: organizationalunit
    objectClass: top
    ou: Dismissed
    description: Dismissed users
    aci: (targetattr="cn || member || gidNumber || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_admin to manage groups"; allow (write, add, delete)(groupdn="ldap:///cn=group_admin,ou=permissions,dc=test,dc=local");)
    aci: (targetattr="cn || member || memberUid || gidNumber || nsUniqueId || description || objectClass")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable anyone group read"; allow (read, search, compare)(userdn="ldap:///anyone");)
    aci: (targetattr="member")(targetfilter="(objectClass=groupOfUniqueNames)")(version 3.0; acl "Enable group_modify to alter members"; allow (write)(groupdn="ldap:///cn=group_modify,ou=permissions,dc=test,dc=local");)

    # Organizational Unit: Permissions
    dn: ou=permissions,dc=test,dc=local
    objectClass: organizationalunit
    objectClass: top
    ou: permissions

    # Organizational Unit: Services
    dn: ou=services,dc=test,dc=local
    objectClass: organizationalunit
    objectClass: top
    ou: services
    aci: (targetattr="objectClass || description || nsUniqueId || cn || memberOf || nsAccountLock")(targetfilter="(objectClass=netscapeServer)")(version 3.0; acl "Enable anyone service account read"; allow (read, search, compare)(userdn="ldap:///anyone");)

    # Permission Groups
    dn: cn=group_admin,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: group_admin

    dn: cn=group_modify,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: group_modify

    dn: cn=user_admin,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: user_admin

    dn: cn=user_modify,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: user_modify

    dn: cn=user_passwd_reset,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: user_passwd_reset

    dn: cn=user_private_read,ou=permissions,dc=test,dc=local
    objectClass: groupOfUniqueNames
    objectClass: top
    cn: user_private_read
```

Применим манифест:

```bash
kubectl -n artldap apply -f manifests-auto/07-configmap-infra.yaml
```

```txt
configmap/artds-infra-ldif created
```

### Job

`Job` находится в файле [manifests-auto/08-job-init.yaml](manifests-auto/08-job-init.yaml).

```yaml
---
apiVersion: batch/v1
kind: Job
metadata:
  name: artds-init
  namespace: artldap
  labels:
    app: artds
    component: initialization
spec:
  # Количество попыток перезапуска при неудаче
  backoffLimit: 3

  # TTL после завершения (автоудаление через 24 часа)
  ttlSecondsAfterFinished: 86400

  template:
    metadata:
      labels:
        app: artds
        component: initialization
    spec:
      # ServiceAccount для доступа к Kubernetes API
      # (необходим для рестарта StatefulSet)
      serviceAccountName: artds-init-sa

      # Политика рестарта: никогда не перезапускать pod после завершения
      restartPolicy: Never

      # ====================================================
      # Контейнер с инициализационным скриптом
      # ====================================================
      containers:
        - name: init
          image: 389ds/dirsrv:3.1
          imagePullPolicy: IfNotPresent

          # Команда: запуск bash скрипта из ConfigMap
          command: ["/bin/bash"]
          args: ["/scripts/script-init.sh"]

          # ====================================================
          # Переменные окружения для скрипта
          # ====================================================
          env:
            # Имя StatefulSet
            - name: DS_POD_NAME
              value: "artds"

            # Имя headless service
            - name: DS_HL_SVC_NAME
              value: "artds-hl"

            # Порт LDAP
            - name: DS_SVC_PORT
              value: "3389"

            # Суффикс LDAP
            - name: DS_SUFFIX_NAME
              value: "dc=test,dc=local"

            # Количество реплик (будем использовать в helmChart)
            - name: NUMBER_OF_REPLICAS
              value: "2"

            # Пароль Directory Manager
            - name: DS_DM_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: artds-admin-secret
                  key: DS_DM_PASSWORD

            # Пароль для репликации
            - name: DS_REPL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: artds-admin-secret
                  key: DS_REPL_PASSWORD

          volumeMounts:
            # Инициализационный скрипт
            - name: init-script
              mountPath: /scripts
              readOnly: true

            # LDIF файлы для структуры дерева
            - name: infra-ldif
              mountPath: /etc/openldap/init
              readOnly: true

          resources:
            requests:
              memory: "128Mi"
              cpu: "250m"
            limits:
              memory: "256Mi"
              cpu: "500m"

      volumes:
        # Скрипт инициализации из ConfigMap
        - name: init-script
          configMap:
            name: artds-init-script
            defaultMode: 0755  # Executable

        # LDIF файлы из ConfigMap
        - name: infra-ldif
          configMap:
            name: artds-infra-ldif
```

Применим манифест с `Job`:

```bash
kubectl -n artldap apply -f manifests-auto/08-job-init.yaml
```

Статус `Job`:

```bash
kubectl get job -n artldap
```

Логи в реальном времени:

```bash
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

### 3. Тест репликации данных

Добавим тестовую запись на artds-0:

```bash
kubectl exec -it -n artldap -c dirsrv artds-0 -- bash -c "cat > /tmp/test-user.ldif << EOF
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

kubectl exec -it -n artldap artds-0 -c dirsrv -- \
    ldapadd -H ldap://artds-0.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /tmp/test-user.ldif
```

Проверим наличие на artds-1:

```bash
kubectl exec -it -n artldap artds-1 -c dirsrv -- \
    ldapsearch -H ldap://artds-1.artds-hl:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "dc=test,dc=local" "(uid=testuser)"
```

Если пользователь найден на artds-1 - репликация работает! ✅

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

