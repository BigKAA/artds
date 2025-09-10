# Artds helm chart

Helm chart дял установки LDAP сервера 389ds.

В чарте гвоздями прибито:
* Максимальное количество подов: 2. 
* `podAntiAffinity` - не получится разметсить два пола на одной ноде.

## values file

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