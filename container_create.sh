#! /bin/bash

docker create \
 -e DS_DM_PASSWORD=password \
 -e DS_SUFFIX_NAME="dc=example,dc=local" \
 -e DS_ERRORLOG_LEVEL
 -m 1024M \
 -p 3389:3389 -p 3636:3636 \
 --name ds \
 389ds/dirsrv:3.1

docker run ds

docker exec -it ds \
dsconf ldap://artds-0.artds-headless:3389 \
-D 'cn=Directory Manager' \
-w 'password' backend suffix list --suffix | grep -Fwq "dc=example,dc=local"

docker exec -it ds \
dsconf ldap://localhost:3389 \
-D 'cn=Directory Manager' \
-w 'password' \
backend create --suffix "dc=example,dc=local" --be-name userroot --create-suffix 

dsconf ldap://artds-0.artds-headless:3389 \
-D 'cn=Directory Manager' \
-w 'password' \
replication status --suffix "dc=system,dc=local"

dsconf ldap://artds-0.artds-headless:3389 -D 'cn=Directory Manager' -w 'password' replication monitor

dsconf ldap://artds-0.artds-headless:3389 \
-D 'cn=Directory Manager' \
-w 'password' \
repl-agmt create --help

dn: cn=memberof task 2, cn=memberof task, cn=tasks, cn=config
objectClass: top
objectClass: extensibleObject
cn: memberof task 2
basedn: dc=system,dc=local

ldapsearch -H "ldap://artds-0.artds-headless:3389" -D 'cn=Directory Manager' -w 'password' -b 'cn=tasks, cn=config' cn

ldapadd -H "ldap://artds-0.artds-headless:3389" -D 'cn=Directory Manager' -w 'password' << EOF
dn: cn=memberof task 2, cn=memberof task, cn=tasks, cn=config
objectClass: top
objectClass: extensibleObject
cn: memberof task 2
basedn: dc=system,dc=local
EOF

ldapsearch -H "ldap://artds-0.artds-headless:3389" -D 'cn=Directory Manager' -w 'password' -b 'cn=plugins,cn=config'

# MemberOf Plugin, plugins, config
dn: cn=MemberOf Plugin,cn=plugins,cn=config
objectClass: top
objectClass: nsSlapdPlugin
objectClass: extensibleObject
cn: MemberOf Plugin
nsslapd-pluginPath: libmemberof-plugin
nsslapd-pluginInitfunc: memberof_postop_init
nsslapd-pluginType: betxnpostoperation
nsslapd-pluginEnabled: off
nsslapd-plugin-depends-on-type: database
memberofgroupattr: member
memberofattr: memberOf
nsslapd-pluginId: none
nsslapd-pluginVersion: none
nsslapd-pluginVendor: none
nsslapd-pluginDescription: none


ldapmodify -H "ldap://artds-0.artds-headless:3389" -D 'cn=Directory Manager' -w 'password' << EOF
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


APISERVER=https://kubernetes.default.svc
# Path to ServiceAccount token
SERVICEACCOUNT=/var/run/secrets/kubernetes.io/serviceaccount
# Read this Pod's namespace
NAMESPACE=$(cat ${SERVICEACCOUNT}/namespace)
# Read the ServiceAccount bearer token
TOKEN=$(cat ${SERVICEACCOUNT}/token)
# Reference the internal certificate authority (CA)
CACERT=${SERVICEACCOUNT}/ca.crt
curl -s --location --cacert ${CACERT} --request PATCH "${APISERVER}/apis/apps/v1/namespaces/${NAMESPACE}/statefullset/artds" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/strategic-merge-patch+json" --data '{
        "spec": {
          "template": {
              "metadata": {
                  "annotations": {
                      "kubectl.kubernetes.io/restartedAt": "'$(date +%Y-%m-%dT%T)'"
                  }
              }
          }
      }
   }'

date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
2025-08-07T10:29:20.651Z

# changelog configuration
dsconf ldap://artds-0.artds-headless:3389 -D 'cn=Directory Manager' -w 'password' replication get-changelog --suffix "dc=system,dc=local"
# текущее состояние базы changelog https://doc.opensuse.org/documentation/leap/security/html/book-security/cha-security-ldap.html#sec-security-ldap-replication-changelog
dn: cn=changelog,cn=userroot,cn=ldbm database,cn=plugins,cn=config
cn: changelog
nsslapd-changelogmaxage: 7d
objectClass: top
objectClass: extensibleObject

# backup
dsconf ldap://artds-0.artds-headless:3389 -D 'cn=Directory Manager' -w 'password' backup create

ls /data/bak
backup-2025-08-11T08:17:13.887071

dsconf ldap://artds-0.artds-headless:3389 -D 'cn=Directory Manager' -w 'password' backup restore /data/bak/backup-2025-08-11T08:17:13.887071