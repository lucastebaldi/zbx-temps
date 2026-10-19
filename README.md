# zbx-temps

Template Para Zabbix Monitoramento de **temperatura de CPU, NVMe e HDs/SSDs** em hosts **Proxmox VE** (ou qualquer Debian/Ubuntu) com **Zabbix 7.0**.

- CPU via `lm-sensors` (Intel `coretemp`, AMD `k10temp`/`zenpower`)
- NVMe e HDs/SSDs SATA/SAS via `smartctl`
- Descoberta automática (LLD) — cada CPU/disco vira um item com triggers próprios
- Discos identificados pelo **número de série**, então o histórico não se perde se `sda` virar `sdb` no boot
- **Não acorda HDs em standby** (`smartctl -n standby`), sem alerta falso quando o disco dorme
- O agent do Zabbix **não precisa de sudo**

---

## Como funciona

```
cron (root, 1x/min)
  └─ zbx-temps.sh ──► /barrainfo/zbx-temps/temps.json
                                   │
Zabbix agent (UserParameter)  ◄────┘  cat temps.json
  └─ item mestre "temps.json"
       ├─ LLD CPU    ─► temps.cpu[<id>]
       ├─ LLD NVMe   ─► temps.nvme[<serial>]
       ├─ LLD Discos ─► temps.disk[<serial>]
       └─ temps.age  ─► alerta se a coleta parar
```

O `smartctl` precisa de root. Então quem coleta é um script rodando como root via cron, e o agent só lê o JSON pronto. Assim não é preciso dar sudo ao usuário `zabbix`.

Exemplo do JSON gerado:

```json
{
  "timestamp": 1792405804,
  "cpu":   [ { "id": "coretemp_0000_package_id_0", "name": "Package id 0", "temp": 52 } ],
  "nvme":  [ { "dev": "nvme0n1", "id": "S4EWNX0R123456", "model": "Samsung SSD 970 EVO Plus 1TB", "temp": 42 } ],
  "disks": [ { "dev": "sda", "id": "WD-WCC7K1234567", "model": "WDC WD40EFRX-68N32N0", "temp": 38 },
             { "dev": "sdb", "id": "ZDH0ABCD", "model": "ST4000VN008" } ]
}
```

Quando um disco não tem o campo `temp`, é porque está em standby ou não devolveu leitura. Nesse caso o Zabbix descarta o valor daquela coleta.

---

## Requisitos

| Componente | Versão |
|---|---|
| Zabbix server/proxy | 7.0 LTS |
| Zabbix agent | agent2 ou agentd (classic) |
| Host | Proxmox VE 8.x / Debian 12 / Ubuntu 22.04+ |
| Pacotes | `lm-sensors`, `smartmontools`, `jq` (o instalador cuida disso) |

---

## Instalação

### 1. No host (como root)

```bash
git clone https://github.com/lucastebaldi/zbx-temps.git
cd zbx-temps
bash instalar-zbx-temps.sh
```

O instalador:

1. instala `lm-sensors`, `smartmontools` e `jq`;
2. roda o `sensors-detect --auto` e carrega `coretemp`, `k10temp` e `drivetemp`;
3. copia o coletor para `/barrainfo/zbx-temps/` e cria o cron em `/etc/cron.d/zbx-temps`;
4. detecta a pasta de configuração do agent e grava o `UserParameter`:
   - `/etc/zabbix/zabbix_agent2.d` → `zabbix-agent2`
   - `/etc/zabbix/zabbix_agentd.d` → `zabbix-agent`
   - `/etc/zabbix/zabbix_agentd.conf.d` → `zabbix-agent`
5. procura definições antigas de `UserParameter=temps.json`. Se achar, pede confirmação (`sim`) para comentar a linha e guarda um backup `.bak`;
6. reinicia o agent e mostra uma leitura de teste.

Estrutura no host:

```
/barrainfo/zbx-temps/
├── zbx-temps.sh   # coletor
├── temps.json     # saída lida pelo agent
└── .lock          # flock do cron
```

### 2. No Zabbix

1. **Coleta de dados → Templates → Importar** → `template_temperaturas_proxmox.yaml`
2. Vincule o template **"Temperaturas Proxmox by Zabbix agent"** ao host.
3. Aguarde a descoberta (até 1 min) e confira em **Dados recentes**.

O template cria o grupo `Templates/barrainfo`.

---

## Macros

| Macro | Padrão | Descrição |
|---|---|---|
| `{$TEMP.CPU.WARN}` | 80 | CPU: alerta (°C) |
| `{$TEMP.CPU.CRIT}` | 90 | CPU: crítico (°C) |
| `{$TEMP.NVME.WARN}` | 65 | NVMe: alerta (°C) |
| `{$TEMP.NVME.CRIT}` | 75 | NVMe: crítico (°C) |
| `{$TEMP.DISK.WARN}` | 45 | HD/SSD SATA-SAS: alerta (°C) |
| `{$TEMP.DISK.CRIT}` | 55 | HD/SSD SATA-SAS: crítico (°C) |
| `{$TEMP.DATA.MAXAGE}` | 300 | Idade máxima do JSON (s) antes de alertar coleta parada |

### Limite por disco (macro com contexto)

As macros de NVMe e disco aceitam o **número de série** como contexto. Com isso você ajusta um disco específico sem mexer nos outros:

```
{$TEMP.DISK.WARN:"WD-WCC7K1234567"} = 50
{$TEMP.NVME.CRIT:"S4EWNX0R123456"} = 80
```

Defina essas macros no host, não no template.

---

## Triggers

| Trigger | Severidade | Regra |
|---|---|---|
| Temperatura crítica | Alta | mínima dos últimos 5 min acima de `*.CRIT` |
| Temperatura alta | Atenção | mínima dos últimos 5 min acima de `*.WARN` (fica suprimido quando o crítico está ativo) |
| Coleta de temperaturas parada | Média | JSON mais velho que `{$TEMP.DATA.MAXAGE}` ou sem dados por 10 min |

A recuperação tem **histerese de 3 °C**: o alerta só fecha quando a máxima de 5 min fica 3 °C abaixo do limite. Isso evita alerta piscando perto do limite.

---

## Troubleshooting

**Testar o coletor manualmente**

```bash
/barrainfo/zbx-temps/zbx-temps.sh && jq . /barrainfo/zbx-temps/temps.json
```

**Testar o agent**

```bash
zabbix_agent2 -t temps.json     # ou: zabbix_agentd -t temps.json
```

**"Coleta de temperaturas parada"**

Primeiro, verifique se o arquivo está sendo atualizado:

```bash
date +%s; jq .timestamp /barrainfo/zbx-temps/temps.json   # diferença deve ser < 60
journalctl -t zbx-temps --since "10 min ago"               # erros do cron
```

Causas comuns:

- **PATH do cron.** O cron roda com `PATH=/usr/bin:/bin`, e o `smartctl` fica em `/usr/sbin`. O script já exporta o PATH completo. Se você editou o script ou o cron, confirme que isso continua lá. Para simular o ambiente do cron:
  ```bash
  env -i PATH=/usr/bin:/bin /barrainfo/zbx-temps/zbx-temps.sh; echo $?
  ```
- **UserParameter antigo apontando para outro arquivo.** Rode `grep -r "temps.json" /etc/zabbix/` e verifique se só existe uma definição.
- **Relógio do host fora de sincronia** com o Zabbix server. Verifique com `timedatectl` (NTP ativo).

**Agent não sobe depois da instalação**

Provavelmente a chave `temps.json` está definida duas vezes. Veja `journalctl -u zabbix-agent*` e remova a definição duplicada.

**CPU não aparece**

```bash
sensors        # precisa listar coretemp-* (Intel) ou k10temp-* (AMD)
modprobe coretemp   # ou k10temp
```

Em VM não há sensor de CPU. O template é para o **host físico**.

**Disco sem temperatura**

- Se é HD em standby, o comportamento é esperado: o valor é descartado e volta quando o disco acordar.
- Se está atrás de **RAID por hardware** (PERC, Smart Array, MegaRAID), o sistema só enxerga o volume lógico. Use `smartctl -d megaraid,N /dev/sdX` ou monitore pelo IPMI/iDRAC/iLO.
- Para testar um disco direto: `smartctl -A /dev/sdX | grep -i temp`

---

## Desinstalação

```bash
rm -f /etc/cron.d/zbx-temps
rm -f /etc/zabbix/zabbix_agent*.d/temps.conf /etc/zabbix/zabbix_agentd.conf.d/temps.conf
rm -rf /barrainfo/zbx-temps
systemctl restart zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent
```

Depois desvincule o template do host no Zabbix.

---

## Arquivos

| Arquivo | Função |
|---|---|
| `zbx-temps.sh` | Coletor. Gera o JSON (roda via cron como root) |
| `instalar-zbx-temps.sh` | Instalador para o host |
| `template_temperaturas_proxmox.yaml` | Template Zabbix 7.0 |

---

Feito por **lucastebaldi**.
