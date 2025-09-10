# Добавление служебных пользователей и групп
logMsg() {
    echo "{\"date\":\"$(date "+%d/%m/%Y %T%z")\",\"facility\":\"$1\",\"message\":\"$2\"}"
}

ldapadd -H ldap://${DS_POD_NAME}-0.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" << EOF
dn: ou=dismissed,dc=system,dc=local
objectClass: organizationalunit
objectClass: top
ou: dismissed
description: Dissmissed users
aci: (targetattr="cn || member || gidNumber || description || objectClass")(
 targetfilter="(objectClass=groupOfNames)")(version 3.0; acl "Enable group_a
 dmin to manage groups"; allow (write, add, delete)(groupdn="ldap:///cn=grou
 p_admin,ou=permissions,dc=system,dc=local");)
aci: (targetattr="cn || member || memberUid || gidNumber || nsUniqueId || de
 scription || objectClass")(targetfilter="(objectClass=groupOfNames)")(versi
 on 3.0; acl "Enable anyone group read"; allow (read, search, compare)(userd
 n="ldap:///anyone");)
aci: (targetattr="member")(targetfilter="(objectClass=groupOfNames)")(versio
 n 3.0; acl "Enable group_modify to alter members"; allow (write)(groupdn="l
 dap:///cn=group_modify,ou=permissions,dc=system,dc=local");)

dn: uid=test_admin,ou=people,dc=system,dc=local
objectClass: inetOrgPerson
objectClass: nsMemberOf
objectClass: organizationalPerson
objectClass: person
objectClass: top
cn: Test
sn: Admin
uid: test_admin
displayName: Test Admin

dn: cn=group1,ou=groups,dc=system,dc=local
objectClass: groupOfUniqueNames
objectClass: top
cn: group1
uniqueMember: uid=test_admin,ou=people,dc=system,dc=local
EOF
