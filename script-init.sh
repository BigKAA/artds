logMsg() {
    echo "{\"date\":\"$(date "+%d/%m/%Y %T%z")\",\"facility\":\"$1\",\"message\":\"$2\"}"
}

# Вычисляет количество подов
PODS_COUNT=$((NUMBER_OF_REPLICAS - 1)) 
if [ $PODS_COUNT -le 0 ]; then
    logMsg ERROR "No pods found in DS cluster."
    exit 1
fi
logMsg INFO "Find $((PODS_COUNT + 1)) pods in DS cluster."

# Инициализация backends в кластере.
for I in $(seq 0 $PODS_COUNT); do
    logMsg INFO "Try to create backend at master: ${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT}"
    TRIALS=0
    until dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD}" backend suffix list > /dev/null 2>&1; do
        sleep 1
        TRIALS=$(( TRIALS + 1 ))
        if [ $TRIALS -gt {{ .Values.jobs.init.initialWaitSeconds }} ]; then logMsg ERROR "Giving up" && exit 1; fi
    done
    logMsg INFO "Connect to ${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT}"
    if ! dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD}" backend suffix list --suffix | grep -Fwq "${DS_SUFFIX_NAME}"; then
        TRIALS=0
        until dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD}" backend create --suffix "${DS_SUFFIX_NAME}" --be-name userroot --create-suffix  > /dev/null 2>&1; do
            sleep 1
            TRIALS=$(( TRIALS + 1 ))
            if [ $TRIALS -gt 30 ]; then logMsg ERROR "Giving up" && exit 1; fi
        done
        logMsg INFO "The database was successfully created"
    else
        logMsg INFO "Backend already present"
    fi
done

# Init replicas if number of pods > 0 (count start from 0)
if [ $PODS_COUNT -gt 0 ]; then
    for I in $(seq 0 $PODS_COUNT); do
        # get status of replication
        if ! dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD}" replication status --suffix ${DS_SUFFIX_NAME} > /dev/null 2>&1; then
            logMsg INFO "Try to init replica at: ${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT}"
            # Пока так. Надо подумать как оптимизировать.
            if [ $I == 0 ]; then
                dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
                    replication enable --suffix="${DS_SUFFIX_NAME}" --role="supplier" --replica-id=$((I + 1)) \
                    --bind-dn="cn=replication manager,cn=config" --bind-passwd="${DS_REPL_PASSWORD}"                     
                dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
                    repl-agmt create --suffix="${DS_SUFFIX_NAME}" --host="${DS_POD_NAME}-1.${DS_HL_SVC_NAME}" --port=${DS_SVC_PORT} \
                    --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="${DS_REPL_PASSWORD}" \
                    --bind-method=SIMPLE --init meTo1
            else
                dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
                    replication enable --suffix="${DS_SUFFIX_NAME}" --role="supplier" --replica-id=$((I + 1)) \
                    --bind-dn="cn=replication manager,cn=config" --bind-passwd="${DS_REPL_PASSWORD}"
                
                dsconf ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" \
                    repl-agmt create --suffix="${DS_SUFFIX_NAME}" --host="${DS_POD_NAME}-0.${DS_HL_SVC_NAME}" --port=${DS_SVC_PORT} \
                    --conn-protocol=LDAP --bind-dn="cn=replication manager,cn=config" --bind-passwd="${DS_REPL_PASSWORD}" \
                    --bind-method=SIMPLE meTo0
            fi
        fi
    done
fi

{{- if .Values.jobs.infra.enable}}
# TODO: добавить контроль наличия ACI
ldapmodify -c -H ldap://${DS_POD_NAME}-0.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" \
-w "${DS_DM_PASSWORD}" -f /etc/openldap/init/init-config-modify.ldiff
ldapadd -c -H ldap://${DS_POD_NAME}-0.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" \
-w "${DS_DM_PASSWORD}" -f /etc/openldap/init/init-config.ldiff
{{- end }}

# Если плагин не включен, включаем плагины и рестартуем поды
PLUGIN_CHANGE=false
for I in $(seq 0 $PODS_COUNT); do
    if ldapsearch -H "ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT}" -D 'cn=Directory Manager' -w "${DS_DM_PASSWORD}" -b 'cn=plugins,cn=config' | grep -A10 'dn: cn=MemberOf Plugin,cn=plugins,cn=config' | grep 'nsslapd-pluginEnabled: off' > /dev/null 2>&1 ; then

        # Enable plugins
        logMsg INFO "Enable plugins at: ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT}"
        ldapmodify -H ldap://${DS_POD_NAME}-${I}.${DS_HL_SVC_NAME}:${DS_SVC_PORT} -D "cn=Directory Manager" -w "${DS_DM_PASSWORD}" > /dev/null 2>&1 << EOF
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
        PLUGIN_CHANGE=true
    fi
done

if [ $PLUGIN_CHANGE == "true" ]; then
    sleep 20
    logMsg INFO "Restart pods after change plugins"
    APISERVER=https://kubernetes.default.svc
    SERVICEACCOUNT=/var/run/secrets/kubernetes.io/serviceaccount
    NAMESPACE=$(cat ${SERVICEACCOUNT}/namespace)
    TOKEN=$(cat ${SERVICEACCOUNT}/token)
    CACERT=${SERVICEACCOUNT}/ca.crt
    curl -s --location --cacert ${CACERT} --request PATCH "${APISERVER}/apis/apps/v1/namespaces/${NAMESPACE}/statefulsets/{{ include "artds.fullname" . }}" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/strategic-merge-patch+json" \
    --data '{
        "spec": {
        "template": {
            "metadata": {
                "annotations": {
                    "kubectl.kubernetes.io/restartedAt": "'$(date +%Y-%m-%dT%T)'"
                }
            }
        }
        }
    }' > /dev/null
fi