#!/usr/bin/env bash
# =============================================================================
# zbx-temps.sh — Coleta temperaturas (CPU, NVMe, HDs/SSDs) para o Zabbix
# barrainfo — Template "Temperaturas Proxmox by Zabbix agent"
#
# Roda como root via cron (1x/min) e grava um JSON em /barrainfo/zbx-temps/temps.json.
# O Zabbix agent só faz "cat" do arquivo — sem sudo para o usuário zabbix.
#
# - CPU: lm-sensors (coretemp Intel / k10temp AMD) — só "Package id N" / Tctl / Tdie
# - Discos: smartctl -n standby (NÃO acorda HD em spindown)
# - ID dos discos = número de série (estável mesmo se sdX mudar no boot)
#
# Dependências: lm-sensors, smartmontools, jq
# =============================================================================
set -uo pipefail

# Cron roda com PATH=/usr/bin:/bin — smartctl fica em /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OUT_DIR="/barrainfo/zbx-temps"
OUT_FILE="${OUT_DIR}/temps.json"
SMART_TIMEOUT=20

for bin in jq lsblk smartctl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERRO: '$bin' não encontrado" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"
chmod 755 /barrainfo "$OUT_DIR"   # usuário zabbix precisa atravessar o caminho
TMP_FILE="$(mktemp "${OUT_DIR}/.temps.XXXXXX")"
DEV_LIST="$(mktemp)"
trap 'rm -f "$TMP_FILE" "$DEV_LIST"' EXIT

# -----------------------------------------------------------------------------
# 1) CPU via lm-sensors
# -----------------------------------------------------------------------------
cpu_json='[]'
if command -v sensors >/dev/null 2>&1; then
    cpu_json="$(sensors -j 2>/dev/null | jq -c '
        [ to_entries[]
          | select(.key | test("^(coretemp|k10temp|zenpower)"))
          | .key as $chip
          | .value | to_entries[]
          | select(.key | test("^(Package id [0-9]+|Tctl|Tdie)$"))
          | {
              id:   (($chip | split("-")[0]) + "_" + ($chip | split("-") | last) + "_" + (.key | ascii_downcase | gsub("[^a-z0-9]+"; "_"))),
              name: .key,
              temp: ([ .value | to_entries[] | select(.key | test("_input$")) | .value ][0])
            }
          | select(.temp != null)
        ]' 2>/dev/null)" || cpu_json='[]'
    [[ -z "$cpu_json" ]] && cpu_json='[]'
fi

# -----------------------------------------------------------------------------
# 2) Discos (NVMe + SATA/SAS) via lsblk + smartctl
#    Modelo/serial vêm do lsblk (udev) para não acordar disco em standby.
# -----------------------------------------------------------------------------
while read -r dev; do
    name="$(jq -r '.name' <<<"$dev")"

    smart="$(timeout "$SMART_TIMEOUT" smartctl -j -A -n standby "/dev/${name}" 2>/dev/null)"
    temp="$(jq -r '.temperature.current // empty' <<<"$smart" 2>/dev/null)"

    jq -cn --argjson d "$dev" --arg temp "$temp" '
        {
          dev:   $d.name,
          id:    (($d.serial // "" | gsub("^\\s+|\\s+$"; "")) as $s
                  | if $s == "" then $d.name else ($s | gsub("[^A-Za-z0-9._-]"; "_")) end),
          model: (($d.model // "desconhecido") | gsub("^\\s+|\\s+$"; "")),
          type:  (if ($d.tran == "nvme") or ($d.name | startswith("nvme")) then "nvme" else "disk" end)
        }
        + (if $temp == "" then {} else { temp: ($temp | tonumber) } end)
    ' >> "$DEV_LIST"
done < <(
    lsblk -dJ -o NAME,TYPE,TRAN,MODEL,SERIAL 2>/dev/null \
    | jq -c '.blockdevices[]
             | select(.type == "disk")
             | select(.name | test("^(sd|nvme|hd)"))'
)

# -----------------------------------------------------------------------------
# 3) Monta o JSON final (escrita atômica)
# -----------------------------------------------------------------------------
jq -n \
    --argjson cpu "$cpu_json" \
    --slurpfile devs "$DEV_LIST" \
    --arg ts "$(date +%s)" '
    ($devs | unique_by(.id)) as $all
    | {
        timestamp: ($ts | tonumber),
        cpu:   $cpu,
        nvme:  [ $all[] | select(.type == "nvme") | del(.type) ],
        disks: [ $all[] | select(.type == "disk") | del(.type) ]
      }' > "$TMP_FILE" || exit 1

chmod 644 "$TMP_FILE"
mv -f "$TMP_FILE" "$OUT_FILE"
