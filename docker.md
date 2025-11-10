# Создание кластера 389ds

В работе используется [официальный контейнер](https://hub.docker.com/r/389ds/dirsrv).

## Требования

Для организации кластера будут использоваться две машины с Linux:

- ldap01.kryukov.local
- ldap02.kryukov.local

Для успешного развертывания кластера 389ds необходимо убедиться в следующем:

- **Две машины с Linux:** `ldap01.kryukov.local` и `ldap02.kryukov.local` с установленным Docker.
- **Сетевая связность:** Машины должны иметь возможность обмениваться данными по портам 3389 и 3636.
- **Разрешение имен (DNS):** Имена хостов `ldap01.kryukov.local` и `ldap02.kryukov.local` должны корректно разрешаться в IP-адреса с обеих машин. Это критично для настройки репликации.
- **Доступ к Docker:** Пользователь, выполняющий команды, должен иметь права на запуск Docker-контейнеров (например, быть в группе `docker` или использовать `sudo`).

## Установка

*Действия выполняем на обеих компьютерах.*

Создаем директорию в которой будут находиться данные:

```bash
mkdir -p /var/ldap
```

Запускаем контейнер:

```bash
docker run -d -m 1024M -p 3389:3389 -p 3636:3636 \
    -e DS_SUFFIX_NAME="dc=cdp,dc=local" \
    -e DS_DM_PASSWORD="password" \
    -e DS_REINDEX=True \
    -v /var/ldap:/data \
    --name ds-test \
    389ds/dirsrv:3.1
```

> **Пояснения к параметрам `docker run`:**
>
> - `-d`: Запускает контейнер в фоновом режиме.
> - `-m 1024M`: Ограничивает использование памяти контейнером до 1024 МБ.
> - `-p 3389:3389 -p 3636:3636`: Пробрасывает порты LDAP (3389) и LDAPS (3636) с хост-машины в контейнер.
> - `-e DS_SUFFIX_NAME="dc=cdp,dc=local"`: Устанавливает базовый суффикс для LDAP-сервера.
> - `-e DS_DM_PASSWORD="password"`: Устанавливает пароль для пользователя `cn=Directory Manager`.
> - `-e DS_REINDEX=True`: Указывает на необходимость переиндексации базы данных при первом запуске.
> - `-v /var/ldap:/data`: Монтирует директорию `/var/ldap` с хост-машины в `/data` внутри контейнера для сохранения данных LDAP.
> - `--name ds-test`: Присваивает контейнеру имя `ds-test`.
> - `389ds/dirsrv:3.1`: Используемый образ Docker.

> **ВНИМАНИЕ:** Замените `password` на надежный, сгенерированный пароль. Не используйте пароль по умолчанию в производственной среде.

Смотрим логи контейнера:

```bash
docker logs ds-test
```

Убеждаемся, что приложение в контейнере работает.

## Инициализация backend

> **Важное замечание:** Команды `dsconf` и `ldapmodify` являются клиентскими утилитами, которые выполняются внутри одного из контейнеров (`ds-test` на `ldap01.kryukov.local`), но могут подключаться к любому доступному LDAP-серверу, указанному в URL (например, `ldap://ldap01.kryukov.local:3389` или `ldap://ldap02.kryukov.local:3389`). Убедитесь, что сетевая связность и разрешение имен между хостами настроены корректно, как указано в разделе "Требования".

Следующие действия можно выполнять на одной машине. Например на `ldap01.kryukov.local`.

Убеждаемся, что LDAP сервер не имеет настроенного бакенда.

Сначала на первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

Затем на втором:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

Должны получить `No backends`.

Создаем конфигурацию для нашего дерева.

На первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend create --suffix "dc=cdp,dc=local" \
    --be-name userroot --create-suffix
```

На втором сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend create --suffix "dc=cdp,dc=local" \
    --be-name userroot --create-suffix
```

В случае успеха должны получить сообщение `The database was sucessfully created`.

На данном этапе мы не используем `--create-entries`. Структура дерева LDAP будет инициализирована при помощи ldif файлов после инициализации репликации.

Проверяем наличие суффикса.

На первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
   backend suffix list
```

Затем на втором:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    backend suffix list
```

## Инициализация репликации

### Проверяем наличие конфигурации репликации на серверах

На первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication status --suffix "dc=cdp,dc=local"
```

Затем на втором:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication status --suffix "dc=cdp,dc=local"
```

Если конфигурация отсутствует, получим сообщение об ошибке: `Error: No object exists given the filter criteria: dc=cdp,dc=local (&(&(objectclass=nsds5Replica))(|(nsDS5ReplicaRoot=dc=cdp,dc=local)))`.

### Добавляем конфигурацию репликации

На первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication enable --suffix="dc=cdp,dc=local" \
    --role="supplier" --replica-id=1 \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password"
```

На втором сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    replication enable --suffix="dc=cdp,dc=local" \
    --role="supplier" --replica-id=2 \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password"
```

> **ВНИМАНИЕ:** Замените `password` на надежный пароль для репликации. Он будет использоваться для аутентификации между серверами.

В случае корректного добавления получим сообщение:  `Replication successfully enabled for "dc=cdp,dc=local"`.

### Добавляем соглашение на репликацию

На первом сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt create --suffix="dc=cdp,dc=local" \
    --host="ldap02.kryukov.local" --port=3389 \
    --conn-protocol=LDAP \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password" \
    --bind-method=SIMPLE meTo1
```

В случае корректного добавления получим сообщение: `Successfully created replication agreement "meTo1"`.

На втором сервере:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt create --suffix="dc=cdp,dc=local" \
    --host="ldap01.kryukov.local" --port=3389 \
    --conn-protocol=LDAP \
    --bind-dn="cn=replication manager,cn=config" \
    --bind-passwd="password" \
    --bind-method=SIMPLE meTo0
```

В случае корректного добавления получим сообщение: `Successfully created replication agreement "meTo0"`.

### Инициализируем репликацию

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt init meTo1 --suffix="dc=cdp,dc=local"
```

> **Примечание:** Инициализация репликации выполняется только на одном сервере (`ldap01.kryukov.local`) для соглашения `meTo1`. Этого достаточно для первоначальной синхронизации данных с `ldap01` на `ldap02`. После этого соглашение `meTo0` на `ldap02` будет автоматически обрабатывать репликацию изменений с `ldap02` на `ldap01`.

В ответ получаем `Agreement initialization started...`.

Проверяем статус соглашения:

```bash
docker exec -it ds-test \
    dsconf ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt status --suffix "dc=cdp,dc=local" meTo1
```

Должны получить что то типа:

```txt
Status For Agreement: "meTo1" (ldap02.kryukov.local:3389)
Replica Enabled: on
Update In Progress: FALSE
Last Update Start: 20251107122302Z
Last Update End: 20251107122302Z
Number Of Changes Sent: 0
Number Of Changes Skipped: None
Last Update Status: Error (0) Replica acquired successfully: Incremental update succeeded
Last Init Start: 20251107122258Z
Last Init End: 20251107122301Z
Last Init Status: Error (0) Total update succeeded
Reap Active: 0
Replication Status: Not in Synchronization: supplier (690de4a6000000020000) consumer (690de12c000100010000) State (green) Reason (error (0) replica acquired successfully: incremental update succeeded)
Replication Lag Time: 00:14:50
```

> **Пояснение к статусу:** Сообщение `Last Update Status: Error (0) Replica acquired successfully` может сбить с толку. В контексте 389ds `Error (0)` означает успешное выполнение операции (код ошибки 0). Таким образом, этот статус говорит о том, что репликация прошла успешно.

Проверяем статус соглашения о репликации на втором сервере.

```bash
docker exec -it ds-test \
    dsconf ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    repl-agmt status --suffix "dc=cdp,dc=local" meTo0
```

```txt
Status For Agreement: "meTo0" (ldap01.kryukov.local:3389)
Replica Enabled: on
Update In Progress: FALSE
Last Update Start: 20251107122302Z
Last Update End: 20251107122302Z
Number Of Changes Sent: 2:1/0 
Number Of Changes Skipped: None
Last Update Status: Error (0) Replica acquired successfully: Incremental update succeeded
Last Init Start: 19700101000000Z
Last Init End: 19700101000000Z
Last Init Status: unavailable
Reap Active: 0
Replication Status: In Synchronization
Replication Lag Time: 00:00:00
```

## ACI

Добавление ACI.

Создаём файл `initConfigModify.ldif`:

```bash
cat > /var/ldap/initConfigModify.ldif << EOF
dn: dc=cdp,dc=local
changetype: modify
add: aci
aci: (targetattr ="*")(version 3.0;acl "Directory Administrators Group";allow (all) (groupdn = "ldap:///cn=Directory Administrators,dc=cdp,dc=local");)
-
changetype: modify
add: aci
aci: (targetattr="ou || objectClass")(targetfilter="(objectClass=organizationalUnit)")(version 3.0; acl "Enable anyone ou read"; allow (read, search, compare)(userdn="ldap:///anyone");)
EOF
```

 Добавляем ACI:

> **Примечание:** Это изменение вносится в суффикс `dc=cdp,dc=local`, для которого мы настроили репликацию. Поэтому достаточно выполнить команду на одном сервере (`ldap01`), и изменение автоматически синхронизируется с `ldap02`.

```bash
docker exec -it ds-test \
    ldapmodify -c -H ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /data/initConfigModify.ldif
```

В случае корректного добавления получим сообщение: `modifying entry "dc=cdp,dc=local"`

Проверяем:

```bash
docker exec -it ds-test \
    ldapsearch -H ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" +
```

Получаем:

```ldif
# extended LDIF
#
# LDAPv3
# base <> (default) with scope subtree
# filter: (objectclass=*)
# requesting: + 
#

# cdp.local
dn: dc=cdp,dc=local
modifyTimestamp: 20251106095236Z
modifiersName: cn=directory manager
creatorsName: cn=directory manager
createTimestamp: 20251106081644Z
entryid: 1
entryUUID: 29ae065e-b893-457b-aecd-b5a00916f10b
aci: (targetattr="dc || description || objectClass")(targetfilter="(objectClas
 s=domain)")(version 3.0; acl "Enable anyone domain read"; allow (read, search
 , compare)(userdn="ldap:///anyone");)
aci: (targetattr ="*")(version 3.0;acl "Directory Administrators Group";allow 
 (all) (groupdn = "ldap:///cn=Directory Administrators,dc=cdp,dc=local");)
aci: (targetattr="ou || objectClass")(targetfilter="(objectClass=organizationa
 lUnit)")(version 3.0; acl "Enable anyone ou read"; allow (read, search, compa
 re)(userdn="ldap:///anyone");)
numSubordinates: 2
nsUniqueId: ec697aad-bae811f0-9b9ddb23-c0e5c100
dsEntryDN: dc=cdp,dc=local
entrydn: dc=cdp,dc=local

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```

Если послать запрос на сервер `ldap02` мы получим аналогичный результат. Это значит, что репликация (как минимум с `ldap01` на `ldap02`) работает.

## Включение плагинов

Нам необходимо включить плагины:

- `Retro Changelog` - сохраняет непосредственно в дереве LDAP все изменения. Удобно для тестирования репликации. **ВНИМАНИЕ: В production-среде использование этого плагина не рекомендуется из-за потенциального увеличения нагрузки и размера базы данных.**
- `MemberOf` - название говорит само за себя.

Создадим файл `plugins.ldif`:

```bash
cat > /var/ldap/plugins.ldif << EOF
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
```

Применим изменения:

> **Важное замечание:** В отличие от изменений ACI, которые мы применяли ранее, конфигурация плагинов хранится в `cn=config`. В данном руководстве мы не настраивали репликацию для этой ветки конфигурации. Поэтому изменения, связанные с плагинами, необходимо применять на **каждом** сервере в кластере отдельно.

```bash
docker exec -it ds-test \
    ldapmodify -H ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /data/plugins.ldif
```

```bash
docker exec -it ds-test \
    ldapmodify -H ldap://ldap02.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -f /data/plugins.ldif
```

Результат работы программы:

```txt
modifying entry "cn=Retro Changelog Plugin,cn=plugins,cn=config"

modifying entry "cn=MemberOf Plugin,cn=plugins,cn=config"
```

После внесенных изменений необходимо перезапустить приложение. В нашем случае - контейнер.

На обеих машинах перезапустите контейнеры.

```bash
docker restart ds-test
```

Проверим наличие изменений в настройках плагина:

```bash
docker exec -it ds-test \
    ldapsearch -H ldap://ldap01.kryukov.local:3389 \
    -D 'cn=Directory Manager' -w "password" \
    -b "cn=plugins,cn=config" cn="MemberOf Plugin"
```

```ldif
# extended LDIF
#
# LDAPv3
# base <cn=plugins,cn=config> with scope subtree
# filter: cn=MemberOf Plugin
# requesting: ALL
#

# MemberOf Plugin, plugins, config
dn: cn=MemberOf Plugin,cn=plugins,cn=config
objectClass: top
objectClass: nsSlapdPlugin
objectClass: extensibleObject
cn: MemberOf Plugin
nsslapd-pluginPath: libmemberof-plugin
nsslapd-pluginInitfunc: memberof_postop_init
nsslapd-pluginType: betxnpostoperation
nsslapd-pluginEnabled: on
nsslapd-plugin-depends-on-type: database
memberofgroupattr: uniqueMember
memberofattr: memberOf
nsslapd-pluginId: memberof
nsslapd-pluginVersion: 3.1.2
nsslapd-pluginVendor: 389 Project
nsslapd-pluginDescription: memberof plugin

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```
