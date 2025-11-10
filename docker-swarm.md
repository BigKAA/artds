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
          - DS_SUFFIX_NAME=dc=cdp,dc=local
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
          - DS_SUFFIX_NAME=dc=cdp,dc=local
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
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" backend create --suffix "dc=cdp,dc=local" --be-name userroot --create-suffix

    # На ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" backend create --suffix "dc=cdp,dc=local" --be-name userroot --create-suffix
    ```

3. **Включение репликации:**

    ```bash
    # На ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" replication enable --suffix="dc=cdp,dc=local" --role="supplier" --replica-id=1 --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS"

    # На ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" replication enable --suffix="dc=cdp,dc=local" --role="supplier" --replica-id=2 --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS"
    ```

4. **Создание соглашений о репликации (Agreements):**

    ```bash
    # Соглашение от ldap01 к ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt create --suffix="dc=cdp,dc=local" --host="ldap02" --port=3389 --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS" --bind-method=SIMPLE meToLdap02

    # Соглашение от ldap02 к ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt create --suffix="dc=cdp,dc=local" --host="ldap01" --port=3389 --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="$REPL_PASS" --bind-method=SIMPLE meToLdap01
    ```

5. **Инициализация репликации:**

    ```bash
    # Инициализируем с ldap01 на ldap02
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt init meToLdap02 --suffix="dc=cdp,dc=local"

    # Инициализируем с ldap02 на ldap01
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap02:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt init meToLdap01 --suffix="dc=cdp,dc=local"
    ```

6. **Проверка статуса:**

    ```bash
    docker exec $LDAP01_CONTAINER_ID dsconf ldap://ldap01:3389 -D 'cn=Directory Manager' -w "$ADMIN_PASS" repl-agmt status --suffix "dc=cdp,dc=local" meToLdap02
    ```

    Убедитесь, что статус `In Synchronization`.

Поздравляем! Вы развернули кластер 389ds на нескольких машинах с помощью Docker Swarm. Дальнейшие шаги, такие как добавление ACI и включение плагинов, могут быть выполнены аналогично, используя `docker exec` и `ldapmodify`.
