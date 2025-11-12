# Создание кластера 389ds с использованием Docker Swarm

**Внимание!** До конца не протестировано...

В этом руководстве описывается, как развернуть отказоустойчивый кластер 389 Directory Server на нескольких машинах, используя Docker Swarm. Этот подход является более надежным и масштабируемым по сравнению с ручным запуском контейнеров на каждом хосте.

**Архитектура:**

- **Docker Swarm:** Объединяет несколько Docker-хостов в единый "рой".
- **Overlay-сеть:** Позволяет контейнерам на разных машинах бесшовно общаться друг с другом.
- **Docker-стек:** Декларативное описание всех сервисов, сетей и томов в одном YAML-файле.
- **Docker Secrets:** Безопасное хранение и передача паролей в контейнеры.

---

## Шаг 1: Требования

1. **Две машины (минимум):** С установленным Docker. В этом руководстве мы будем называть их `ldap01` (менеджер) и `ldap02` (рабочий узел).
2. **Сетевая связность:** Машины должны находиться в одной сети и иметь возможность общаться по следующим портам:
    - **TCP 2377:** для управления кластером.
    - **TCP/UDP 7946:** для коммуникации между узлами.
    - **UDP 4789:** для overlay-сети.
3. **Открытые порты для LDAP:** Убедитесь, что на хостах открыты порты `3389` (LDAP) и `3636` (LDAPS) для внешнего доступа.

---

## Шаг 2: Инициализация Docker Swarm

Эти команды превратят ваши отдельные Docker-хосты в единый кластер.

1. **На машине `ldap01` (менеджер), выполните:**

    ```bash
    # Замените <IP_АДРЕС_МАШИНЫ_LDAP01> на реальный IP-адрес ldap01
    docker swarm init --advertise-addr <IP_АДРЕС_МАШИНЫ_LDAP01>
    ```

    Эта команда инициализирует "рой" и выведет команду для присоединения других узлов. Скопируйте ее. Она будет выглядеть примерно так:

    ```txt
    docker swarm join --token SWMTKN-1-xxxx... <IP_АДРЕС_МАШИНЫ_LDAP01>:2377
    ```

2. **На машине `ldap02` (рабочий узел), выполните команду, которую вы скопировали на предыдущем шаге.**

3. **Проверьте, что оба узла в "рое".** На машине `ldap01` выполните:

    ```bash
    docker node ls
    ```

    Вы должны увидеть оба узла в статусе `Ready`.

---

## Шаг 3: Создание секретов и файла стека

Мы будем использовать Docker Secrets для безопасного управления паролями.

1. **Создайте секреты (выполняется на `ldap01`):**

    > **ВНИМАНИЕ:** Замените `YourStrongAdminPassword` и `YourStrongReplicationPassword` на сгенерированные, надежные пароли.

    ```bash
    echo "YourStrongAdminPassword" | docker secret create ds_admin_password -
    echo "YourStrongReplicationPassword" | docker secret create ds_replication_password -
    ```

2. **Создайте файл `ldap-stack.yml` (на `ldap01`):**

    Создайте файл с таким именем и поместите в него следующее содержимое.

    ```yaml
    version: '3.8'

    services:
      ldap01:
        image: 389ds/dirsrv:latest
        hostname: ldap01
        ports:
          - "3389:3389"
          - "3636:3636"
        volumes:
          - ldap01_data:/data
        secrets:
          - source: ds_admin_password
            target: ds_dm_password_file
        environment:
          - DS_DM_PASSWORD_FILE=/run/secrets/ds_dm_password_file
          - DS_SUFFIX_NAME=dc=test,dc=local
          - DS_REINDEX=True
        networks:
          - ldap_net
        deploy:
          replicas: 1
          placement:
            constraints:
              - node.hostname == ldap01

      ldap02:
        image: 389ds/dirsrv:latest
        hostname: ldap02
        ports:
          - "4389:3389" # Используем другой порт на хосте, чтобы избежать конфликтов, если оба сервиса окажутся на одной машине
          - "4636:3636"
        volumes:
          - ldap02_data:/data
        secrets:
          - source: ds_admin_password
            target: ds_dm_password_file
        environment:
          - DS_DM_PASSWORD_FILE=/run/secrets/ds_dm_password_file
          - DS_SUFFIX_NAME=dc=test,dc=local
          - DS_REINDEX=True
        networks:
          - ldap_net
        deploy:
          replicas: 1
          placement:
            constraints:
              - node.hostname == ldap02

    volumes:
      ldap01_data:
      ldap02_data:

    networks:
      ldap_net:
        driver: overlay

    secrets:
      ds_admin_password:
        external: true
      ds_replication_password:
        external: true
    ```

    > **Примечание:** `placement.constraints` жестко привязывают сервисы к конкретным машинам. Это полезно для предсказуемости. Если это не требуется, их можно убрать, и Swarm сам решит, где запускать контейнеры.

---

## Шаг 4: Развертывание стека

Теперь, когда все готово, развернем наш кластер одной командой.

1. **На машине `ldap01` выполните:**

    ```bash
    docker stack deploy -c ldap-stack.yml ldap_cluster
    ```

2. **Проверьте статус развертывания:**

    ```bash
    docker stack services ldap_cluster
    ```

    Подождите, пока в колонке `REPLICAS` для обоих сервисов не будет `1/1`. Это может занять несколько минут, пока образы скачиваются и контейнеры запускаются.

---

## Шаг 5: Настройка репликации и кластера

После того как оба сервиса запущены, можно приступать к настройке репликации. Все команды выполняются на машине-менеджере (`ldap01`).

> **Важное замечание:** Для выполнения команд внутри контейнера нам нужно его имя. Мы можем получить его с помощью `docker ps`. Например, `ldap_cluster_ldap01.1.xxxx`. Для удобства можно использовать `docker exec $(docker ps -q -f name=ldap_cluster_ldap01.1) ...`

1. **Определим переменные для удобства:**

    ```bash
    # Получаем пароли из Docker Secrets
    ADMIN_PASS=$(docker secret inspect -f '{{printf "%s" .Spec.Data}}' ds_admin_password | base64 -d)
    REPL_PASS=$(docker secret inspect -f '{{printf "%s" .Spec.Data}}' ds_replication_password | base64 -d)

    # Находим ID контейнеров
    LDAP01_CONTAINER_ID=$(docker ps -q -f name=ldap_cluster_ldap01.1)
    LDAP02_CONTAINER_ID=$(docker ps -q -f name=ldap_cluster_ldap02.1)
    ```

2. **Создание Backend:**

    ```bash
    # На ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" backend create --suffix "dc=test,dc=local" --be-name userroot --create-suffix

    # На ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" backend create --suffix "dc=test,dc=local" --be-name userroot --create-suffix
    ```

3. **Включение репликации:**

    ```bash
    # На ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" replication enable --suffix="dc=test,dc=local" --role="supplier" --replica-id=1 --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS"

    # На ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" replication enable --suffix="dc=test,dc=local" --role="supplier" --replica-id=2 --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS"
    ```

4. **Создание соглашений о репликации (Agreements):**

    ```bash
    # Соглашение от ldap01 к ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt create --suffix="dc=test,dc=local" --host="ldap02" --port=3389 --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS" --bind-method=SIMPLE meToLdap02

    # Соглашение от ldap02 к ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt create --suffix="dc=test,dc=local" --host="ldap01" --port=3389 --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS" --bind-method=SIMPLE meToLdap01
    ```

5. **Инициализация репликации:**

    ```bash
    # Инициализируем с ldap01 на ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt init meToLdap02 --suffix="dc=test,dc=local"

    # Инициализируем с ldap02 на ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt init meToLdap01 --suffix="dc=test,dc=local"
    ```

6. **Проверка статуса:**

    ```bash
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt status --suffix "dc=test,dc=local" meToLdap02
    ```

    Убедитесь, что статус `In Synchronization`.

---

## Шаг 6: JSON Logging Configuration

389 Directory Server версии 3.0+ поддерживает JSON-формат логов для Access, Error и Audit логов. Это упрощает интеграцию с системами централизованного логирования и мониторинга.

### Включение JSON логирования

На каждом сервисе выполните команды для настройки JSON логирования:

```bash
# Определяем переменные
LDAP01_CONTAINER_ID=$(docker ps -q -f name=ldap_cluster_ldap01.1)
LDAP02_CONTAINER_ID=$(docker ps -q -f name=ldap_cluster_ldap02.1)
ADMIN_PASS=$(docker secret inspect -f '{{printf "%s" .Spec.Data}}' ds_admin_password | base64 -d)

# Настройка JSON логов на ldap01
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging access set log-format json
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging access set time-format "%Y-%m-%dT%H:%M:%S%z"
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging error set log-format json
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging error set time-format "%Y-%m-%dT%H:%M:%S%z"
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging audit set log-format json

# Настройка JSON логов на ldap02
docker exec $LDAP02_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging access set log-format json
docker exec $LDAP02_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging access set time-format "%Y-%m-%dT%H:%M:%S%z"
docker exec $LDAP02_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging error set log-format json
docker exec $LDAP02_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging error set time-format "%Y-%m-%dT%H:%M:%S%z"
docker exec $LDAP02_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging audit set log-format json
```

**Примечание:** Audit Log JSON доступен начиная с 389ds 3.1.1+. Для более ранних версий эта команда будет игнорироваться.

### Просмотр JSON логов

Для просмотра JSON логов можно использовать `jq`:

```bash
# Access Log
docker exec $LDAP01_CONTAINER_ID tail -f /var/log/dirsrv/slapd-localhost/access | jq .

# Error Log
docker exec $LDAP01_CONTAINER_ID tail -f /var/log/dirsrv/slapd-localhost/errors | jq .

# Фильтрация по уровню
docker exec $LDAP01_CONTAINER_ID tail -f /var/log/dirsrv/slapd-localhost/errors | jq 'select(.level == "ERROR")'

# Фильтрация по пользователю
docker exec $LDAP01_CONTAINER_ID tail -f /var/log/dirsrv/slapd-localhost/access | jq 'select(.bind_dn | contains("uid=testuser"))'
```

### Автоматизация через скрипт

Для упрощения настройки JSON логирования используйте готовый скрипт [docker/enable-json-logging.sh](docker/enable-json-logging.sh):

```bash
# Скопировать скрипт в контейнер ldap01
docker cp docker/enable-json-logging.sh $(docker ps -q -f name=ldap_cluster_ldap01.1):/tmp/

# Выполнить настройку для ldap01
docker exec $(docker ps -q -f name=ldap_cluster_ldap01.1) bash -c "
  export ENABLE_JSON_LOGGING=true
  export DS_DM_PASSWORD='YourStrongAdminPassword'
  export DS_INSTANCE='ldap://ldap01:3389'
  /tmp/enable-json-logging.sh
"

# Аналогично для ldap02
docker cp docker/enable-json-logging.sh $(docker ps -q -f name=ldap_cluster_ldap02.1):/tmp/

docker exec $(docker ps -q -f name=ldap_cluster_ldap02.1) bash -c "
  export ENABLE_JSON_LOGGING=true
  export DS_DM_PASSWORD='YourStrongAdminPassword'
  export DS_INSTANCE='ldap://ldap02:3389'
  /tmp/enable-json-logging.sh
"
```

### Интеграция с системами логирования

JSON логи легко интегрировать с ELK Stack, Loki, Splunk или другими системами:

```bash
# Пример для Promtail/Loki
docker service logs -f ldap_cluster_ldap01 | jq .
```

### Откат на стандартный формат

Если необходимо вернуться к обычному текстовому формату:

```bash
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging access set log-format default
docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" logging error set log-format default
```

---

Поздравляем! Вы развернули кластер 389ds на нескольких машинах с помощью Docker Swarm с поддержкой JSON логирования. Дальнейшие шаги, такие как добавление ACI и включение плагинов, могут быть выполнены аналогично, используя `docker exec` и `ldapmodify`.
