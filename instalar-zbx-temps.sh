#!/usr/bin/env bash
# =============================================================================
# instalar-zbx-temps.sh — Instala a coleta de temperaturas para o Zabbix
# barrainfo — rodar como root no host Proxmox, na mesma pasta do zbx-temps.sh
#
# Tudo fica em /barrainfo/zbx-temps:
#   zbx-temps.sh  (coletor)   temps.json  (saída lida pelo agent)   .lock
# =============================================================================
set -euo pipefail

BASE_DIR="/barrainfo/zbx-temps"

[[ $EUID -eq 0 ]] || { echo "Rode como root."; exit 1; }
[[ -f ./zbx-temps.sh ]] || { echo "zbx-temps.sh não encontrado na pasta atual."; exit 1; }

echo "== [1/5] Pacotes (lm-sensors, smartmontools, jq)"
apt-get update -qq
apt-get install -y -qq lm-sensors smartmontools jq

echo "== [2/5] Detecção de sensores"
sensors-detect --auto >/dev/null || true
# Módulos comuns; ignora os que não existirem nesse hardware
for mod in coretemp k10temp drivetemp; do modprobe "$mod" 2>/dev/null || true; done

echo "== [3/5] Script de coleta + cron"
install -d -m 755 /barrainfo "$BASE_DIR"
chmod 755 /barrainfo "$BASE_DIR"   # usuário zabbix precisa atravessar o caminho
# Se o instalador já estiver rodando de dentro de $BASE_DIR, não copia sobre si mesmo
if [[ "$(realpath ./zbx-temps.sh)" != "$BASE_DIR/zbx-temps.sh" ]]; then
    install -m 755 ./zbx-temps.sh "$BASE_DIR/zbx-temps.sh"
else
    chmod 755 "$BASE_DIR/zbx-temps.sh"
fi
cat > /etc/cron.d/zbx-temps <<EOF
# Coleta de temperaturas para o Zabbix (barrainfo) — erros vão pro journal: journalctl -t zbx-temps
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root flock -n ${BASE_DIR}/.lock ${BASE_DIR}/zbx-temps.sh 2>&1 | logger -t zbx-temps
EOF
chmod 644 /etc/cron.d/zbx-temps
"$BASE_DIR/zbx-temps.sh"

echo "== [4/5] UserParameter no Zabbix agent"
if [[ -d /etc/zabbix/zabbix_agent2.d ]]; then
    CONF_DIR=/etc/zabbix/zabbix_agent2.d; SVC=zabbix-agent2
elif [[ -d /etc/zabbix/zabbix_agentd.d ]]; then
    CONF_DIR=/etc/zabbix/zabbix_agentd.d; SVC=zabbix-agent
elif [[ -d /etc/zabbix/zabbix_agentd.conf.d ]]; then
    CONF_DIR=/etc/zabbix/zabbix_agentd.conf.d; SVC=zabbix-agent
else
    echo "Zabbix agent não encontrado (nem agent2 nem agentd)."; exit 1
fi
echo "   Pasta do agent: ${CONF_DIR} (serviço ${SVC})"

# Chave duplicada impede o agent de subir — procura definições antigas (ex.: feitas à mão)
mapfile -t DUPES < <(grep -lE '^[[:space:]]*UserParameter[[:space:]]*=[[:space:]]*temps\.json[[:space:]]*,' \
    /etc/zabbix/zabbix_agent*.conf "${CONF_DIR}"/*.conf 2>/dev/null | grep -vx "${CONF_DIR}/temps.conf" || true)
if (( ${#DUPES[@]} > 0 )); then
    echo "   ATENÇÃO: UserParameter temps.json já definido em:"
    for f in "${DUPES[@]}"; do
        grep -nE '^[[:space:]]*UserParameter[[:space:]]*=[[:space:]]*temps\.json' "$f" | sed "s#^#     ${f}:#"
    done
    read -rp "   Comentar essas linhas (backup .bak)? Digite 'sim': " RESP
    [[ "$RESP" == "sim" ]] || { echo "Abortado. Remova a definição antiga e rode de novo."; exit 1; }
    for f in "${DUPES[@]}"; do
        sed -i.bak -E 's/^([[:space:]]*UserParameter[[:space:]]*=[[:space:]]*temps\.json[[:space:]]*,)/# (zbx-temps instalador) \1/' "$f"
    done
fi

echo "UserParameter=temps.json,cat ${BASE_DIR}/temps.json" > "${CONF_DIR}/temps.conf"
systemctl restart "$SVC"

echo "== [5/5] Teste"
sleep 2
if command -v zabbix_agent2 >/dev/null 2>&1; then
    zabbix_agent2 -t temps.json | head -c 600; echo
else
    zabbix_agentd -t temps.json | head -c 600; echo
fi
echo
jq -r '
  "CPU:    " + ([.cpu[]   | "\(.name)=\(.temp)°C"] | join("  ")),
  "NVMe:   " + ([.nvme[]  | "\(.dev)=" + (if .temp then "\(.temp)°C" else "sem leitura" end)] | join("  ")),
  "Discos: " + ([.disks[] | "\(.dev)=" + (if .temp then "\(.temp)°C" else "standby/sem leitura" end)] | join("  "))
' "$BASE_DIR/temps.json"
echo
echo "OK. Agora vincule o template 'Temperaturas Proxmox by Zabbix agent' ao host."
