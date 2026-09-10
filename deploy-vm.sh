#!/bin/bash
# ==============================================================================
# Cloud-Init Proxmox - Instalador Modular V8.4
# Cambios 8.0: red por MAC fija (OUI Proxmox) en vez de match por driver/nombre
# Cambios 8.1: set -E + trap EXIT (rollback cubre fallos dentro de funciones),
# checksum por nombre remoto (Ubuntu nunca se verificaba), validación AUTH_MODE/
# claves SSH/DNS/VLAN/índice storage, disco mínimo = tamaño virtual de la imagen,
# pvesm set preserva content real, VMID chequeado a nivel cluster, descarga a
# .part, MAC sin colisiones, bootcmd once-per-instance, netplan 600, timeout 600s
# Cambios 8.2: caché de imágenes indexada por build (el nombre en disco lleva el
# hash), así 'latest'/'current' al republicar ya no invalidan lo descargado; una
# build nueva se ofrece en vez de imponerse (IMAGE_REFRESH=ask|never|always),
# fallback a la build anterior si el mirror falla, y purga opcional de builds viejas
# Cambios 8.3: modo `--cambiar-ip <VMID>` para reconfigurar la red de una VM ya
# creada. Hace falta porque con `cicustom network=` el campo "IP Config" del panel
# NO se aplica (manda el snippet) y ademas editar el snippet no cambia el
# instance-id, asi que cloud-init se cree ya aprovisionado y no reescribe netplan:
# hay que regenerar snippet + ipconfig0, `cloud-init clean` y apagar/encender.
# Se avisa de esa trampa al terminar el despliegue y en las notas de la VM.
# Cambios 8.4: el snippet de red ya NO se usa siempre, solo donde el generador
# nativo de Proxmox se queda corto (/32, que necesita on-link, e IPv6 estatico,
# que necesita accept-ra:false). Para el resto la config nativa es equivalente
# --tambien empareja por MAC-- y asi la pestana Cloud-Init del panel vuelve a
# funcionar. --cambiar-ip sirve en ambos casos y migra de un modo al otro.
# ==============================================================================

set -Eeuo pipefail

# ==================== GLOBALES Y COLORES ====================
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

IMAGE_URL=""; IMAGE_RELPATH=""; IMAGE_NAME=""; FILE_PATH=""; CHECKSUM_URL=""; CHECKSUM_ALGO=""
STORAGE_IMG=""; STORAGE_SNIP=""; SNIPPET_FULL_PATH=""
VMID=""; NOMBRE=""; RAM=""; CPU=""; DISK=""
AUTH_MODE=""; ROOT_PASS_HASH=""; SSH_PWAUTH="false"; SSHD_PASSWORD_AUTH="no"; SSH_KEYS=()
BRIDGE=""; VLAN_TAG=""; IPV4_VAL=""; IPV4_CIDR=""; GW_IPV4=""
IPV6_CONFIGURED=false; GW_IPV6=""; DNS_SERVERS=""
OS_TYPE="debian"; OS_PRETTY=""
CPU_TYPE="host"; STORAGE_SSD_FLAG=""
SUCCESS=false; ROLLBACK_EXECUTED=false; LOG_FILE=""; NETWORK_YAML_FILE=""; YAML_FILE=""
VM_MAC=""; IMG_MIN_GB="2"; PERMIT_ROOT_LOGIN=""
IPV6_VAL=""
MODE="deploy"; TARGET_VMID=""

case "${1:-}" in
    --cambiar-ip|--change-ip) MODE="change-ip"; TARGET_VMID="${2:-}" ;;
    -h|--help)                MODE="help" ;;
    "")                       ;;
    *) echo "Opcion desconocida: $1 (usa --help)" >&2; exit 1 ;;
esac

# ==================== FUNCIONES DE VALIDACIÓN Y CONTROL ====================
valid_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { IFS='.' read -r a b c d <<< "$1"; (( a<=255 && b<=255 && c<=255 && d<=255 )); }; }
valid_cidr() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 32 )); }
valid_ipv6_addr() {
    local addr="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])" "$addr" 2>/dev/null
        return $?
    fi
    [[ "$addr" =~ ^(::)?([0-9a-fA-F]{1,4}:){1,7}(:|[0-9a-fA-F]{1,4})$|^::$ ]]
}
valid_ipv6_cidr() {
    local ip_cidr="$1" addr prefix
    [[ "$ip_cidr" == */* ]] || return 1
    addr="${ip_cidr%/*}"; prefix="${ip_cidr##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 128 )) || return 1
    valid_ipv6_addr "$addr"
}

# El VMID es único a nivel CLUSTER (VMs y CTs de todos los nodos). qm status
# solo ve el nodo local, así que primero consultamos /cluster/resources; si la
# API no responde, caemos al chequeo local como mínimo.
vmid_exists() {
    local id="$1" out
    out=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || out=""
    if [ -n "$out" ]; then
        if printf '%s' "$out" | python3 -c 'import json,sys; ids={str(r.get("vmid")) for r in json.load(sys.stdin)}; sys.exit(0 if sys.argv[1] in ids else 1)' "$id" 2>/dev/null; then
            return 0
        fi
    fi
    qm status "$id" &>/dev/null
}

# Mide qué mirror responde más rápido DESDE ESTE NODO y devuelve su URL base.
# Las sondas (512 KB con timeout corto) corren EN PARALELO, así un mirror
# colgado cuesta el timeout una sola vez y no la suma de todos. Resuelve el
# caso real de los frontends round-robin (cloud.debian.org / cdimage.debian.org)
# cuyo pool a veces tiene IPs muertas: wget se quedaba minutos esperando.
pick_fastest_mirror() {
    local relpath="$1"; shift
    local tmpdir base host f i=0 pids=() winner="" line

    # Un solo candidato: nada que medir (ej. el CDN de Ubuntu ya geo-rutea).
    if [ $# -eq 1 ]; then echo "$1"; return 0; fi

    tmpdir=$(mktemp -d) || { echo "$1"; return 0; }
    echo -e "\n${BLUE}==> Midiendo mirrors para elegir el más rápido...${NC}" >&2

    for base in "$@"; do
        (
            probe_start=$(date +%s%N)
            if timeout 8 wget -q --tries=1 --timeout=6 \
                 --header="Range: bytes=0-262143" -O /dev/null "${base}/${relpath}" 2>/dev/null; then
                probe_end=$(date +%s%N)
                echo "$(( (probe_end - probe_start) / 1000000 )) ${base}" > "${tmpdir}/${i}"
            fi
        ) &
        pids+=("$!")
        i=$((i+1))
    done
    wait "${pids[@]}" 2>/dev/null || true

    for f in "$tmpdir"/*; do
        [ -f "$f" ] || continue
        line=$(cat "$f")
        host=$(echo "${line#* }" | cut -d/ -f3)
        printf "  ${CYAN}%-30s %6s ms${NC}\n" "$host" "${line%% *}" >&2
    done

    winner=$(cat "$tmpdir"/* 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-) || true
    rm -rf "$tmpdir"

    if [ -z "$winner" ]; then
        echo -e "  ${YELLOW}[AVISO] Ningún mirror respondió a la sonda; se usará el primero de la lista.${NC}" >&2
        return 1
    fi
    echo -e "  ${GREEN}[OK] Mirror elegido: $(echo "$winner" | cut -d/ -f3)${NC}" >&2
    echo "$winner"
}

# ==================== CACHÉ DE IMÁGENES (INDEXADA POR BUILD) ====================
# 'latest/' (Debian) y 'current/' (Ubuntu) son punteros MÓVILES: el upstream
# republica la imagen cada 1-2 semanas y su checksum cambia con ella. Guardando
# la imagen bajo un nombre fijo, la caché caducaba sola en cada rebuild y el
# script re-descargaba ~350 MB aunque el archivo local estuviera intacto. Ahora
# el nombre en disco lleva el hash de la build, así conviven varias y una build
# ya descargada NUNCA se vuelve a bajar.

# Descarga a .part y renombra al terminar: una descarga interrumpida jamás queda
# en caché como si fuera una imagen completa.
download_image() {
    local url="$1" dest="$2"
    echo -e "${YELLOW}==> Descargando $(basename "$url")...${NC}"
    if ! wget -q --show-progress --tries=5 --waitretry=10 --timeout=30 -O "${dest}.part" "$url"; then
        rm -f "${dest}.part"
        return 1
    fi
    mv -f "${dest}.part" "$dest"
}

# Builds de la misma familia ya presentes en caché, la más reciente primero.
cache_builds() {
    local dir="$1" base="$2" ext="$3"
    ls -1t "${dir}/${base}-"*."${ext}" 2>/dev/null || true
}

# Tamaño de la descarga pendiente, solo para informar antes de preguntar.
remote_size_mb() {
    local url="$1" len
    len=$(wget -qS --spider --timeout=8 --tries=1 "$url" 2>&1 \
          | awk '/[Cc]ontent-[Ll]ength:/ {print $2}' | tr -d '\r' | tail -1)
    if [[ "$len" =~ ^[0-9]+$ ]]; then echo $(( len / 1048576 )); else echo "?"; fi
}

# Cada rebuild del upstream deja atrás ~350 MB. Se avisa y se ofrece limpiar,
# pero nunca se borra sin preguntar.
prune_old_builds() {
    local dir="$1" base="$2" ext="$3" keep="$4"
    local old=() f total=0 R=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "$keep" ] && continue
        old+=("$f")
        total=$(( total + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done < <(cache_builds "$dir" "$base" "$ext")
    if [ ${#old[@]} -eq 0 ]; then return 0; fi
    echo -e "\n${CYAN}==> Builds antiguas en caché: ${#old[@]} ($(( total / 1048576 )) MB)${NC}"
    printf "   %s\n" "${old[@]##*/}"
    if [ ! -t 0 ]; then return 0; fi
    read -r -p "   ¿Borrarlas? [s/N]: " R || R=""
    if [[ "${R,,}" =~ ^(s|si|sí|y|yes)$ ]]; then
        rm -f "${old[@]}"
        echo -e "   ${GREEN}[OK] Liberados $(( total / 1048576 )) MB.${NC}"
    fi
    return 0
}

# ==================== FUNCIONES DE DETECCIÓN (GENÉRICO PARA CUALQUIER NODO) ====================
# Elige el tipo de CPU según si el nodo es standalone o pertenece a un cluster:
# "host" da el máximo rendimiento pero fija la VM a la CPU exacta del nodo (rompe
# migración en vivo si el cluster tiene hardware distinto entre nodos). En cluster
# usamos un baseline portable con AES-NI (relevante para VPN/TLS/DNS-over-TLS).
detect_cpu_type() {
    if [ -f /etc/pve/corosync.conf ]; then
        CPU_TYPE="x86-64-v2-AES"
        echo -e "  ${CYAN}[INFO] Nodo en cluster detectado → cpu=${CPU_TYPE} (portable, compatible con migración en vivo)${NC}"
    else
        CPU_TYPE="host"
        echo -e "  ${CYAN}[INFO] Nodo standalone detectado → cpu=${CPU_TYPE} (máximo rendimiento)${NC}"
    fi
}

# Detecta si el storage de disco es no-rotacional (SSD/NVMe) para activar ssd=1
# (mejora el scheduler de I/O del guest y confirma que discard=on hace TRIM real).
# Soporta lvm/lvmthin, dir y zfspool. Si no se puede determinar (storages de red
# como nfs/cifs/rbd/cephfs, o falla la detección), no asume nada: omite ssd=1.
detect_storage_rotational() {
    local storage="$1" stype vg pool path devs="" dev r any_rota=0 any_ssd=0
    stype=$(pvesm status 2>/dev/null | awk -v s="$storage" '$1==s {print $2}')

    case "$stype" in
        lvm|lvmthin)
            vg=$(pvesh get "/storage/${storage}" --output-format json 2>/dev/null \
                | python3 -c 'import json,sys;print(json.load(sys.stdin).get("vgname",""))' 2>/dev/null)
            [ -n "$vg" ] && devs=$(pvs --noheadings -o pv_name -S "vg_name=${vg}" 2>/dev/null)
            ;;
        dir)
            path=$(pvesh get "/storage/${storage}" --output-format json 2>/dev/null \
                | python3 -c 'import json,sys;print(json.load(sys.stdin).get("path",""))' 2>/dev/null)
            [ -n "$path" ] && devs=$(findmnt -no SOURCE --target "$path" 2>/dev/null)
            ;;
        zfspool)
            pool=$(pvesh get "/storage/${storage}" --output-format json 2>/dev/null \
                | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pool",""))' 2>/dev/null)
            [ -n "$pool" ] && devs=$(zpool list -vH "${pool%%/*}" 2>/dev/null \
                | awk '$1 !~ /^(mirror|raidz[0-9]?|spare|log|cache|special|-|NAME)/ {print "/dev/"$1}')
            ;;
        *)
            return 1
            ;;
    esac

    [ -z "$devs" ] && return 1

    for dev in $devs; do
        r=$(lsblk -ndo ROTA "$dev" 2>/dev/null | head -1)
        [ "$r" = "1" ] && any_rota=1
        [ "$r" = "0" ] && any_ssd=1
    done

    if [ "$any_rota" -eq 1 ]; then
        echo "1"; return 0
    elif [ "$any_ssd" -eq 1 ]; then
        echo "0"; return 0
    fi
    return 1
}

rollback() {
    if [ "$ROLLBACK_EXECUTED" = true ]; then return; fi
    ROLLBACK_EXECUTED=true

    if [ "$SUCCESS" = true ]; then return; fi

    set +e

    # Limpiar descarga parcial de imagen si fue interrumpida (la descarga
    # completa se hace a .part y se renombra al final, así el caché nunca
    # queda con una imagen a medias)
    [ -n "${FILE_PATH:-}" ] && rm -f "${FILE_PATH}.part"

    if [ -z "$VMID" ]; then
        echo -e "\n${YELLOW}[ALTO] Instalación abortada. No se hicieron cambios en el nodo.${NC}"
        exit 1
    fi

    echo -e "\n${RED}[ERROR] CANCELACIÓN/ERROR - Limpiando recursos parciales de la VM ${VMID}...${NC}"

    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}==> Revisa el archivo de log para ver el error exacto: ${LOG_FILE}${NC}"
    fi

    qm status "$VMID" &>/dev/null && {
        qm stop "$VMID" --skiplock 1 2>/dev/null
        qm destroy "$VMID" --purge 1 2>/dev/null
    }
    [ -n "${YAML_FILE:-}" ] && [ -f "$YAML_FILE" ] && rm -f "$YAML_FILE"
    [ -n "${NETWORK_YAML_FILE:-}" ] && [ -f "$NETWORK_YAML_FILE" ] && rm -f "$NETWORK_YAML_FILE"

    exit 1
}
# EXIT incluido: los `exit 1` explícitos NO disparan ERR, y sin -E el trap ERR
# ni siquiera se hereda dentro de funciones — con ERR+EXIT+set -E el rollback
# cubre todos los caminos de fallo (el guard SUCCESS evita limpiar en éxito).
trap rollback INT TERM ERR EXIT

# ==============================================================================
# FASE 1: SELECCIÓN DE SISTEMA OPERATIVO Y DESCARGA (ACTUALIZADO V7.2)
# ==============================================================================
select_os_and_download() {
    clear 2>/dev/null || true   # sin TTY (ssh no interactivo) clear falla y set -e mataría el script
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Cloud-Init Proxmox - Despliegue Automatizado    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${BLUE}==> Selecciona el Sistema Operativo Base:${NC}"
    echo "  1) Debian 12 (Bookworm)"
    echo "  2) Debian 13 (Trixie)"
    echo "  3) Ubuntu 20.04 LTS (Focal Fossa)"
    echo "  4) Ubuntu 22.04 LTS (Jammy Jellyfish)"
    echo "  5) Ubuntu 24.04 LTS (Noble Numbat)"
    
    read -p "Opción [1]: " OS_OPT; OS_OPT=${OS_OPT:-1}

    case "$OS_OPT" in
        1)
            IMAGE_RELPATH="bookworm/latest/debian-12-genericcloud-amd64.qcow2"
            IMAGE_NAME="debian-12-genericcloud-amd64.qcow2"
            OS_PRETTY="Debian 12 (Bookworm)"
            CHECKSUM_ALGO="sha512sum"
            OS_TYPE="debian"
            ;;
        2)
            IMAGE_RELPATH="trixie/latest/debian-13-genericcloud-amd64.qcow2"
            IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
            OS_PRETTY="Debian 13 (Trixie)"
            CHECKSUM_ALGO="sha512sum"
            OS_TYPE="debian"
            ;;
        3)
            IMAGE_RELPATH="focal/current/focal-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-20.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 20.04 LTS (Focal)"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        4)
            IMAGE_RELPATH="jammy/current/jammy-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-22.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 22.04 LTS (Jammy)"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        5)
            IMAGE_RELPATH="noble/current/noble-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 24.04 LTS (Noble)"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        *)
            echo -e "${RED}[ERROR] Opción inválida.${NC}"; exit 1
            ;;
    esac

    # Mirrors candidatos. Se mide cuál responde más rápido DESDE ESTE NODO y se
    # usa ese para imagen y checksums (ambos del MISMO mirror: si vinieran de
    # mirrors con sincronización distinta, el hash no cuadraría y el script
    # entraría en re-descarga innecesaria).
    local MIRRORS=()
    if [ "$OS_TYPE" = "debian" ]; then
        # cloud.debian.org y cdimage.debian.org son round-robin sobre el mismo
        # clúster; cuando una de sus IPs está caída wget se cuelga varios
        # minutos. Los backends individuales permiten esquivar la IP muerta.
        MIRRORS=(
            "https://cloud.debian.org/images/cloud"
            "https://cdimage.debian.org/cdimage/cloud"
            "https://gemmei.ftp.acc.umu.se/cdimage/cloud"
            "https://laotzu.ftp.acc.umu.se/cdimage/cloud"
            "https://saimei.ftp.acc.umu.se/cdimage/cloud"
        )
    else
        # cloud-images.ubuntu.com ya es un CDN con geo-routing: sirve desde el
        # POP más cercano al nodo, así que no hay nada que medir (un solo
        # candidato = la sonda se salta y no cuesta tiempo).
        MIRRORS=("https://cloud-images.ubuntu.com")
    fi

    local BASE_URL
    BASE_URL=$(pick_fastest_mirror "$IMAGE_RELPATH" "${MIRRORS[@]}") || BASE_URL="${MIRRORS[0]}"

    IMAGE_URL="${BASE_URL}/${IMAGE_RELPATH}"
    local SUMS_NAME
    [ "$CHECKSUM_ALGO" = "sha512sum" ] && SUMS_NAME="SHA512SUMS" || SUMS_NAME="SHA256SUMS"
    CHECKSUM_URL="${BASE_URL}/$(dirname "$IMAGE_RELPATH")/${SUMS_NAME}"

    local CACHE_DIR="/var/lib/vz/template/iso"
    local IMG_BASE="${IMAGE_NAME%.*}" IMG_EXT="${IMAGE_NAME##*.}"
    local LEGACY_PATH="${CACHE_DIR}/${IMAGE_NAME}"
    mkdir -p "$CACHE_DIR"

    echo -e "\n${BLUE}==> Verificando conectividad y caché de imagen...${NC}"
    if ! wget -q --spider --timeout=5 "https://8.8.8.8" &>/dev/null && ! ping -c 1 8.8.8.8 &>/dev/null; then
         echo -e "${RED}[ERROR] Sin conexión a Internet en el nodo Proxmox.${NC}"; exit 1
    fi

    # --- Qué build sirve el upstream AHORA, identificada por su checksum ---
    # OJO: en el archivo de sumas la imagen aparece con su nombre ORIGINAL
    # (ej. noble-server-cloudimg-amd64.img), no con el renombrado local.
    local REMOTE_NAME EXPECTED=""
    REMOTE_NAME=$(basename "$IMAGE_URL")
    if [ -n "$CHECKSUM_URL" ]; then
        local SUMS_FILE
        SUMS_FILE=$(mktemp)
        if wget -q --tries=3 --timeout=15 -O "$SUMS_FILE" "$CHECKSUM_URL"; then
            EXPECTED=$(awk -v n="$REMOTE_NAME" '$2==n || $2=="*"n {print $1; exit}' "$SUMS_FILE")
        fi
        rm -f "$SUMS_FILE"
    fi

    if [ -z "$EXPECTED" ]; then
        # Sin sumas no se puede ni identificar ni validar la build: se reutiliza
        # lo que haya en caché antes que bajar a ciegas algo no verificable.
        echo -e "${YELLOW}[AVISO] No se pudo obtener el archivo de sumas: sin verificación de integridad.${NC}"
        FILE_PATH=$(cache_builds "$CACHE_DIR" "$IMG_BASE" "$IMG_EXT" | head -1)
        [ -z "$FILE_PATH" ] && [ -f "$LEGACY_PATH" ] && FILE_PATH="$LEGACY_PATH"
        if [ -n "$FILE_PATH" ]; then
            echo -e "${GREEN}[OK] Usando la imagen en caché: $(basename "$FILE_PATH")${NC}"
        else
            FILE_PATH="$LEGACY_PATH"
            download_image "$IMAGE_URL" "$FILE_PATH" || {
                echo -e "${RED}[ERROR] Falló la descarga. Verifica la red o la URL.${NC}"; exit 1; }
        fi
    else
        FILE_PATH="${CACHE_DIR}/${IMG_BASE}-${EXPECTED:0:12}.${IMG_EXT}"

        # Migración del esquema anterior (archivo único sin sufijo): se reetiqueta
        # con su propio hash. Si resulta ser la build que sirve el upstream ahora,
        # el destino es justo FILE_PATH y no se descarga nada.
        if [ -f "$LEGACY_PATH" ]; then
            echo -e "${BLUE}==> Reetiquetando la imagen heredada del esquema anterior...${NC}"
            local LEGACY_SUM
            LEGACY_SUM=$($CHECKSUM_ALGO "$LEGACY_PATH" | awk '{print $1}')
            mv -f "$LEGACY_PATH" "${CACHE_DIR}/${IMG_BASE}-${LEGACY_SUM:0:12}.${IMG_EXT}"
        fi

        if [ -f "$FILE_PATH" ]; then
            # El nombre lleva el hash de la build, así que recalcularlo valida de
            # paso que el archivo no se corrompió en disco.
            echo -e "${BLUE}==> Verificando la imagen en caché (${CHECKSUM_ALGO})...${NC}"
            if [ "$($CHECKSUM_ALGO "$FILE_PATH" | awk '{print $1}')" = "$EXPECTED" ]; then
                echo -e "${GREEN}[OK] La build actual ya está en caché — no hace falta descargar.${NC}"
            else
                echo -e "${YELLOW}[AVISO] La copia en caché está corrupta; se descarga de nuevo.${NC}"
                rm -f "$FILE_PATH"
            fi
        fi

        if [ ! -f "$FILE_PATH" ]; then
            # Que haya una build anterior es lo NORMAL (el upstream republica cada
            # 1-2 semanas), no un error: se deja elegir en vez de imponer la
            # descarga. La imagen vieja sirve igual porque cloud-init hace
            # package_upgrade en el primer arranque.
            local OLD_BUILD USE_CACHE="no"
            OLD_BUILD=$(cache_builds "$CACHE_DIR" "$IMG_BASE" "$IMG_EXT" | head -1)
            if [ -n "$OLD_BUILD" ]; then
                local AGE_DAYS
                AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$OLD_BUILD") ) / 86400 ))
                echo -e "\n${YELLOW}[AVISO] El upstream publicó una build más reciente que la que tienes.${NC}"
                echo -e "   ${CYAN}En caché:${NC} $(basename "$OLD_BUILD")  (${AGE_DAYS} día/s)"
                echo -e "   ${CYAN}Nueva   :${NC} ${EXPECTED:0:12}…  (~$(remote_size_mb "$IMAGE_URL") MB de descarga)"
                case "${IMAGE_REFRESH:-ask}" in
                    never)  USE_CACHE="si" ;;
                    always) USE_CACHE="no" ;;
                    *)
                        local R=""
                        read -r -p "   ¿Usar la imagen en caché y no descargar? [S/n]: " R || R=""
                        [[ "${R,,}" =~ ^(n|no)$ ]] || USE_CACHE="si"
                        ;;
                esac
            fi

            if [ "$USE_CACHE" = "si" ]; then
                FILE_PATH="$OLD_BUILD"
                echo -e "${GREEN}[OK] Usando la build en caché (cloud-init actualizará los paquetes al arrancar).${NC}"
            elif ! download_image "$IMAGE_URL" "$FILE_PATH"; then
                # Mirror caído: mejor desplegar con la build anterior que abortar.
                if [ -n "$OLD_BUILD" ]; then
                    echo -e "${YELLOW}[AVISO] Falló la descarga; se continúa con la build anterior en caché.${NC}"
                    FILE_PATH="$OLD_BUILD"
                else
                    echo -e "${RED}[ERROR] Falló la descarga. Verifica la red o la URL.${NC}"; exit 1
                fi
            else
                local ACTUAL
                ACTUAL=$($CHECKSUM_ALGO "$FILE_PATH" | awk '{print $1}')
                if [ "$EXPECTED" != "$ACTUAL" ]; then
                    # Descarga fresca que no cuadra -> corrupta o alterada
                    echo -e "${RED}[ERROR] Checksum MISMATCH tras descarga fresca. La imagen puede estar corrupta o alterada.${NC}"
                    echo -e "${RED}   Esperado: $EXPECTED${NC}"
                    echo -e "${RED}   Obtenido: $ACTUAL${NC}"
                    rm -f "$FILE_PATH"
                    exit 1
                fi
                echo -e "${GREEN}[OK] Checksum OK (${CHECKSUM_ALGO}).${NC}"
            fi
        fi
    fi

    IMAGE_NAME=$(basename "$FILE_PATH")
    prune_old_builds "$CACHE_DIR" "$IMG_BASE" "$IMG_EXT" "$FILE_PATH"

    # Tamaño virtual de la imagen = disco mínimo de la VM: qm resize no puede
    # ENCOGER un disco, así que pedir menos que esto haría fallar el deploy
    # (Debian 13 genericcloud = 3G, Ubuntu noble = 3.5G...). Redondeo hacia arriba.
    if command -v qemu-img >/dev/null 2>&1; then
        local VSIZE
        VSIZE=$(qemu-img info --output=json "$FILE_PATH" 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null || true)
        if [[ "$VSIZE" =~ ^[0-9]+$ ]] && (( VSIZE > 0 )); then
            IMG_MIN_GB=$(( (VSIZE + 1073741823) / 1073741824 ))
            echo -e "  ${CYAN}[INFO] Disco virtual de la imagen: ${IMG_MIN_GB} GB (mínimo aceptado para la VM)${NC}"
        fi
    fi
}

# ==============================================================================
# FASE 2: AUTO-SELECCIÓN DE STORAGE PARA IMÁGENES
# ==============================================================================
auto_select_image_storage() {
    echo -e "\n${BLUE}==> Storages disponibles para el Disco Virtual:${NC}"
    mapfile -t STORAGES_IMG < <(pvesm status --content images 2>/dev/null | awk '$3=="active" {print $1}')
    
    if [ ${#STORAGES_IMG[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] No hay storages de imágenes activos.${NC}"; exit 1
    fi

    for i in "${!STORAGES_IMG[@]}"; do
        S="${STORAGES_IMG[$i]}"
        FREE_KB=$(pvesm status | awk -v s="$S" '$1==s {print $6}')
        FREE_GB=$(( FREE_KB / 1048576 ))
        S_TYPE=$(pvesm status | awk -v s="$S" '$1==s {print $2}')
        echo "  $((i+1))) ${S} (${S_TYPE}, ${FREE_GB} GB libres)"
    done

    if [ ${#STORAGES_IMG[@]} -eq 1 ]; then
        STORAGE_IMG="${STORAGES_IMG[0]}"
        echo -e "  ${GREEN}[OK] Storage único seleccionado: ${CYAN}$STORAGE_IMG${NC}"
    else
        while true; do
            read -p "Selecciona storage para disco VM [1]: " IMG_IDX; IMG_IDX=${IMG_IDX:-1}
            if [[ "$IMG_IDX" =~ ^[0-9]+$ ]] && (( IMG_IDX >= 1 && IMG_IDX <= ${#STORAGES_IMG[@]} )); then
                STORAGE_IMG="${STORAGES_IMG[$((IMG_IDX-1))]}"
                break
            fi
            echo -e "${RED}[ERROR] Índice inválido. Selecciona un número del 1 al ${#STORAGES_IMG[@]}.${NC}"
        done
        echo -e "${GREEN}[OK] Storage seleccionado: ${CYAN}$STORAGE_IMG${NC}"
    fi

    local ROTA
    ROTA=$(detect_storage_rotational "$STORAGE_IMG") || true
    if [ "$ROTA" = "0" ]; then
        STORAGE_SSD_FLAG=",ssd=1"
        echo -e "  ${CYAN}[INFO] Medio detectado: SSD/NVMe → ssd=1${NC}"
    elif [ "$ROTA" = "1" ]; then
        echo -e "  ${CYAN}[INFO] Medio detectado: HDD rotacional → ssd=1 omitido${NC}"
    else
        echo -e "  ${CYAN}[INFO] No se pudo determinar el tipo de medio (storage remoto/red) → ssd=1 omitido${NC}"
    fi
}

# ==============================================================================
# FASE 3: AUTO-SELECCIÓN DE STORAGE PARA SNIPPETS
# ==============================================================================
ask_snippet_storage() {
    echo -e "\n${BLUE}==> Detectando storage para Snippets/Cloud-Init...${NC}"
    mapfile -t STORAGES_SNIP < <(pvesm status 2>/dev/null | awk '$3=="active" && $2 ~ /^(dir|nfs|cifs|cephfs)$/ {print $1}')

    if [ ${#STORAGES_SNIP[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] No hay storages tipo dir activos para snippets.${NC}"; exit 1
    fi

    # Orden de preferencia (NO tomar a ciegas el primero de la lista: en nodos
    # con un share de backups montado, el orden alfabético dejaba los snippets
    # en el NAS y la VM no arrancaba si el NAS no estaba montado al boot):
    #   1) storages que YA tienen "snippets" en su content (no tocamos config)
    #   2) tipo dir (local) antes que nfs/cifs/cephfs (remoto)
    # Si hay empate en el primer puesto, se pregunta igual que con el disco.
    local S_CONTENT S_TYPE RANK BEST_RANK
    local -a RANKED=()
    for S in "${STORAGES_SNIP[@]}"; do
        S_CONTENT=$(pvesh get "/storage/${S}" --output-format json 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin).get("content",""))' 2>/dev/null || true)
        S_TYPE=$(pvesm status 2>/dev/null | awk -v s="$S" '$1==s {print $2}')
        RANK=3
        [ "$S_TYPE" = "dir" ] && RANK=2
        [[ ",${S_CONTENT}," == *",snippets,"* ]] && RANK=$(( RANK - 2 ))
        RANKED+=("${RANK} ${S}")
    done

    BEST_RANK=$(printf '%s\n' "${RANKED[@]}" | sort -s -n -k1,1 | head -1 | awk '{print $1}')
    local -a TIED=()
    for R in "${RANKED[@]}"; do
        [ "${R%% *}" = "$BEST_RANK" ] && TIED+=("${R#* }")
    done

    if [ ${#TIED[@]} -eq 1 ]; then
        STORAGE_SNIP="${TIED[0]}"
        echo -e "${GREEN}[OK] Snippets en: ${CYAN}$STORAGE_SNIP${NC}"
    else
        for i in "${!TIED[@]}"; do
            S="${TIED[$i]}"
            S_TYPE=$(pvesm status 2>/dev/null | awk -v s="$S" '$1==s {print $2}')
            echo "  $((i+1))) ${S} (${S_TYPE})"
        done
        while true; do
            read -p "Selecciona storage para snippets/cloud-init [1]: " SNIP_IDX; SNIP_IDX=${SNIP_IDX:-1}
            if [[ "$SNIP_IDX" =~ ^[0-9]+$ ]] && (( SNIP_IDX >= 1 && SNIP_IDX <= ${#TIED[@]} )); then
                STORAGE_SNIP="${TIED[$((SNIP_IDX-1))]}"
                break
            fi
            echo -e "${RED}[ERROR] Índice inválido. Selecciona un número del 1 al ${#TIED[@]}.${NC}"
        done
        echo -e "${GREEN}[OK] Snippets en: ${CYAN}$STORAGE_SNIP${NC}"
    fi

    # Habilitar snippets PRESERVANDO el content real del storage. El content
    # se lee de la API (/storage/<id>), no de `pvesm status` (cuya columna 2
    # es el TIPO, no el content). Solo se AÑADE "snippets" si falta — jamás se
    # reconstruye la lista, para no borrar tipos existentes (iso, vztmpl,
    # backup, import de PVE 8.2+, etc.) de la config del nodo.
    CURRENT_CONTENT=$(pvesh get "/storage/${STORAGE_SNIP}" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("content",""))' 2>/dev/null || true)

    if [ -n "$CURRENT_CONTENT" ]; then
        if [[ ",${CURRENT_CONTENT}," != *",snippets,"* ]]; then
            echo -e "${CYAN}==> Habilitando snippets en $STORAGE_SNIP (preservando: ${CURRENT_CONTENT})...${NC}"
            pvesm set "$STORAGE_SNIP" --content "${CURRENT_CONTENT},snippets" || true
        fi
    else
        # No se pudo leer el content: NO tocar la config del storage.
        echo -e "${YELLOW}[AVISO] No se pudo leer el content de ${STORAGE_SNIP}; si 'snippets' no está habilitado, actívalo manualmente (Datacenter → Storage).${NC}"
    fi

    local SNIP_BASE
    SNIP_BASE=$(pvesh get "/storage/${STORAGE_SNIP}" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("path",""))' 2>/dev/null || true)
    [ -z "$SNIP_BASE" ] && SNIP_BASE=$(awk "/^dir: ${STORAGE_SNIP}\$/{f=1;next} f&&/^\\s*path /{print \$2;exit}" /etc/pve/storage.cfg 2>/dev/null)
    [ -z "$SNIP_BASE" ] && SNIP_BASE="/var/lib/vz"
    SNIPPET_FULL_PATH="${SNIP_BASE}/snippets"
    mkdir -p "$SNIPPET_FULL_PATH"
}
# ==============================================================================
# FASE 4: DIMENSIONAMIENTO E IDENTIDAD
# ==============================================================================
ask_vmid_and_name() {
    echo -e "\n${BLUE}==> Identificación de la Máquina Virtual${NC}"
    while true; do
        PROXIMO_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
        read -p "ID VM [$PROXIMO_ID]: " INPUT_VMID
        VMID=${INPUT_VMID:-$PROXIMO_ID}
        
        if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [ "$VMID" -lt 100 ]; then
            echo -e "${RED}[ERROR] El ID debe ser un número ≥ 100.${NC}"
        elif vmid_exists "$VMID"; then
            echo -e "${RED}[ERROR] El ID $VMID ya existe en el cluster (VM o CT, puede estar en otro nodo). Elige otro.${NC}"
        else
            break
        fi
    done

    YAML_FILE="${SNIPPET_FULL_PATH}/user-data-${VMID}.yaml"
    NETWORK_YAML_FILE="${SNIPPET_FULL_PATH}/network-data-${VMID}.yaml"
    mkdir -p /var/log/proxmox-deploy
    LOG_FILE="/var/log/proxmox-deploy/deploy_VM${VMID}_$(date +%Y%m%d-%H%M%S).log"

    while true; do
        read -p "Nombre VM (ej. webserver-01): " NOMBRE
        if [[ -z "$NOMBRE" ]]; then
            echo -e "${RED}[ERROR] El nombre es obligatorio.${NC}"
        elif ! [[ "$NOMBRE" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            echo -e "${RED}[ERROR] Nombre inválido. Usa solo letras, dígitos y '-' (1-63 chars, sin empezar/terminar con '-').${NC}"
        else
            break
        fi
    done
}

ask_resources() {
    echo -e "\n${BLUE}==> Recursos de Hardware${NC}"
    
    while true; do
        read -p "RAM MB [2048]: " RAM; RAM=${RAM:-2048}
        [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) && break || echo -e "${RED}[ERROR] RAM inválida (mínimo 512)${NC}"
    done
    
    while true; do
        read -p "CPU cores [2]: " CPU; CPU=${CPU:-2}
        [[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) && break || echo -e "${RED}[ERROR] CPU inválida (mínimo 1)${NC}"
    done
    
    while true; do
        read -p "Disco GB [20]: " DISK; DISK=${DISK:-20}
        # Mínimo = tamaño virtual de la imagen (qm resize no puede encoger)
        [[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= IMG_MIN_GB )) || { echo -e "${RED}[ERROR] Disco mínimo ${IMG_MIN_GB}GB (la imagen ${IMAGE_NAME} no se puede encoger)${NC}"; continue; }

        local AVAIL_KB=$(pvesm status | awk -v s="$STORAGE_IMG" '$1==s {print $6}')
        if [[ -z "$AVAIL_KB" ]]; then break; fi
        local AVAIL_GB=$(( AVAIL_KB / 1048576 ))

        if (( DISK > AVAIL_GB )); then
            echo -e "${RED}[ERROR] Espacio insuficiente. Pediste ${DISK}GB pero solo hay ${AVAIL_GB}GB libres en $STORAGE_IMG.${NC}"
        else
            echo -e "${GREEN}[OK] Recursos verificados correctamente.${NC}"
            break
        fi
    done
}

# ==============================================================================
# FASE 5: AUTENTICACIÓN
# ==============================================================================
ask_auth_mode() {
    echo -e "\n${BLUE}==> Autenticación:${NC}"
    echo "1) Solo root + contraseña"
    echo "2) Solo clave SSH"
    echo "3) SSH + contraseña root (recomendado)"
    # Validar: un typo aquí (ej. "4") dejaba una VM SIN password y SIN claves
    # — completamente inaccesible, incluso por consola serial.
    while true; do
        read -p "Opción [3]: " AUTH_MODE; AUTH_MODE=${AUTH_MODE:-3}
        [[ "$AUTH_MODE" =~ ^[123]$ ]] && break
        echo -e "${RED}[ERROR] Opción inválida. Debe ser 1, 2 o 3.${NC}"
    done

    if [[ "$AUTH_MODE" == "1" ]] || [[ "$AUTH_MODE" == "3" ]]; then
        while true; do
            read -s -p "Password root: " PASS1; echo
            read -s -p "Confirma: " PASS2; echo
            [[ "$PASS1" == "$PASS2" && -n "$PASS1" ]] && break
            echo -e "${RED}[ERROR] Las contraseñas no coinciden${NC}"
        done

        if ! command -v mkpasswd >/dev/null 2>&1; then
            echo -e "${YELLOW}==> mkpasswd no encontrado, instalando paquete 'whois'...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whois >/dev/null 2>&1 || {
                echo -e "${RED}[ERROR] No se pudo instalar 'whois' (requerido para hashear el password).${NC}"
                echo -e "${RED}   Ejecuta: apt-get install whois   y reintenta.${NC}"
                unset PASS1 PASS2
                exit 1
            }
        fi

        ROOT_PASS_HASH=$(mkpasswd --method=sha-512 --stdin <<< "$PASS1")
        unset PASS1 PASS2
        if [[ "$ROOT_PASS_HASH" != \$6\$* ]]; then
            echo -e "${RED}[ERROR] mkpasswd falló generando hash SHA-512.${NC}"; exit 1
        fi
        echo -e "${GREEN}[OK] Contraseña encriptada exitosamente (SHA-512).${NC}"
        SSH_PWAUTH="true"
        SSHD_PASSWORD_AUTH="yes"
    fi

    if [[ "$AUTH_MODE" == "2" || "$AUTH_MODE" == "3" ]]; then
        echo -e "${YELLOW}Pega tus claves SSH públicas (una por línea, presiona Enter en una línea vacía para terminar):${NC}"
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            # Validar formato: una clave truncada/typo en modo 2 = VM inaccesible
            if ssh-keygen -lf /dev/stdin <<< "$line" >/dev/null 2>&1; then
                SSH_KEYS+=("$line")
                echo -e "  ${GREEN}[OK] Clave válida agregada (${#SSH_KEYS[@]}).${NC}"
            else
                echo -e "  ${RED}[ERROR] No parece una clave pública SSH válida — ignorada. Pega otra o Enter para terminar.${NC}"
            fi
        done
        if [[ "$AUTH_MODE" == "2" && ${#SSH_KEYS[@]} -eq 0 ]]; then
            echo -e "${RED}[ERROR] Modo 'solo clave SSH' requiere al menos una clave. Abortando.${NC}"
            exit 1
        fi
    fi

    # Derivar directivas sshd según el modo elegido (respetado en runcmd)
    if [[ "$AUTH_MODE" == "2" ]]; then
        PERMIT_ROOT_LOGIN="prohibit-password"   # solo clave SSH
    else
        PERMIT_ROOT_LOGIN="yes"                 # password permitido
    fi
}

# ==============================================================================
# FASE 6: RED
# ==============================================================================
ask_network() {
    echo -e "\n${BLUE}==> Configuración de Red${NC}"

    # Solo bridges de Proxmox (vmbrN): excluye docker0, fwbr*, y los
    # sub-bridges vmbrXvY que crea el tagging VLAN en bridges legacy.
    mapfile -t BRIDGES < <(ip -br link show type bridge 2>/dev/null | awk '$1 ~ /^vmbr[0-9]+$/ && $2!="DOWN" {print $1}')
    [ ${#BRIDGES[@]} -eq 0 ] && { echo -e "${RED}[ERROR] No hay bridges principales activos (ej. vmbr0)${NC}"; exit 1; }

    if [ ${#BRIDGES[@]} -eq 1 ]; then
        BRIDGE="${BRIDGES[0]}"
        echo -e "  [OK] Bridge único detectado y seleccionado: ${CYAN}${BRIDGE}${NC}"
    else
    for i in "${!BRIDGES[@]}"; do
        BR_NAME="${BRIDGES[$i]}"
        BR_COMMENT=$( (ip link show "$BR_NAME" 2>/dev/null | grep -oP "alias \K.*" || true) 2>/dev/null )
        [ -z "$BR_COMMENT" ] && BR_COMMENT=$( (grep -A1 "iface $BR_NAME" /etc/network/interfaces 2>/dev/null | grep "^#" | sed "s/^#//" | head -1) 2>/dev/null || true )
        [ -n "$BR_COMMENT" ] && echo "  $((i+1))) ${BR_NAME} (${BR_COMMENT})" || echo "  $((i+1))) ${BR_NAME}"
    done
        while true; do
            read -p "Selecciona Bridge [1]: " BR_IDX
            BR_IDX=${BR_IDX:-1}
            if [[ "$BR_IDX" =~ ^[0-9]+$ ]] && (( BR_IDX >= 1 && BR_IDX <= ${#BRIDGES[@]} )); then
                BRIDGE="${BRIDGES[$((BR_IDX-1))]}"
                break
            else
                echo -e "${RED}[ERROR] Índice inválido. Por favor selecciona un número del 1 al ${#BRIDGES[@]}.${NC}"
            fi
        done
    fi

    while true; do
        read -p "VLAN ID (Enter para omitir, sin VLAN): " VLAN_INPUT
        [[ -z "$VLAN_INPUT" ]] && break
        if [[ "$VLAN_INPUT" =~ ^[0-9]+$ ]] && (( VLAN_INPUT >= 1 && VLAN_INPUT <= 4094 )); then
            VLAN_TAG=",tag=${VLAN_INPUT}"
            break
        fi
        echo -e "${RED}[ERROR] VLAN inválida (debe ser entre 1 y 4094)${NC}"
    done

    while true; do
        read -p "IPv4 (ej. 192.168.1.100): " IPV4_VAL
        if valid_ipv4 "$IPV4_VAL"; then break; else echo -e "${RED}[ERROR] IPv4 inválida${NC}"; fi
    done

    while true; do
        read -p "CIDR [24]: " IPV4_CIDR; IPV4_CIDR=${IPV4_CIDR:-24}
        if valid_cidr "$IPV4_CIDR"; then break; else echo -e "${RED}[ERROR] CIDR inválido${NC}"; fi
    done

    while true; do
        read -p "Gateway IPv4: " GW_IPV4
        if valid_ipv4 "$GW_IPV4"; then break; else echo -e "${RED}[ERROR] Gateway IPv4 inválido${NC}"; fi
    done

    echo -e "\n${BLUE}==> IPv6 (Opcional - Enter para omitir)${NC}"
    while true; do
        read -p "IPv6/prefijo (ej. 2803:c310:ff10::a/64): " IPV6_VAL
        [[ -z "$IPV6_VAL" ]] && break
        valid_ipv6_cidr "$IPV6_VAL" && break
        echo -e "${RED}[ERROR] IPv6/prefijo inválido (formato esperado dirección/prefijo, ej. 2803:c310:ff10::a/64)${NC}"
    done
    if [[ -n "$IPV6_VAL" ]]; then
        while true; do
            read -p "Gateway IPv6: " GW_IPV6
            valid_ipv6_addr "$GW_IPV6" && break
            echo -e "${RED}[ERROR] Gateway IPv6 inválido${NC}"
        done
        IPV6_CONFIGURED=true
    fi

    if [ "$IPV6_CONFIGURED" = true ]; then
        DEFAULT_DNS="8.8.8.8 2001:4860:4860::8888"
    else
        DEFAULT_DNS="8.8.8.8 1.1.1.1"
    fi

    # Validar DNS: estos valores acaban dentro de dos YAMLs y en --nameserver;
    # texto arbitrario rompería la resolución del guest en silencio.
    local ns dns_ok
    while true; do
        read -p "DNS [$DEFAULT_DNS]: " DNS_INPUT
        DNS_SERVERS=${DNS_INPUT:-$DEFAULT_DNS}
        dns_ok=true
        for ns in $DNS_SERVERS; do
            if ! valid_ipv4 "$ns" && ! valid_ipv6_addr "$ns"; then
                dns_ok=false
                echo -e "${RED}[ERROR] '$ns' no es una IP válida (separa varios DNS con espacios)${NC}"
                break
            fi
        done
        [ "$dns_ok" = true ] && break
    done

    # MAC fija con el OUI de Proxmox (BC:24:11). Se fija en net0 y se usa para
    # emparejar la interfaz por MAC en el network-config, en vez de por nombre
    # (ens18/enp*sN) o por driver — matchear por driver no se traduce al
    # renderer v1/ENI de Debian (que no trae netplan) y deja la VM sin ruta.
    # Emparejar por MAC funciona en cualquier Proxmox y renderer (ENI/networkd/netplan).
    # Se regenera si colisiona con alguna VM/CT existente del cluster (los
    # configs guardan la MAC en mayúsculas → grep -i).
    while : ; do
        VM_MAC=$(printf 'bc:24:11:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
        grep -riqs "$VM_MAC" /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null || break
        echo -e "  ${YELLOW}[AVISO] MAC ${VM_MAC} ya usada por otra VM/CT — regenerando...${NC}"
    done
}

# ==============================================================================
# FASE 7: CONFIRMACIÓN
# ==============================================================================
confirm_deployment() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    RESUMEN VM                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "OS Base  : ${IMAGE_NAME}"
    echo -e "VMID     : ${VMID} (${NOMBRE})"
    echo -e "Storage  : ${STORAGE_IMG} (${DISK} GB)"
    echo -e "Red      : ${BRIDGE}${VLAN_TAG:-}"
    echo -e "IPv4     : ${IPV4_VAL}/${IPV4_CIDR} → gw ${GW_IPV4}"
    [ "$IPV6_CONFIGURED" = true ] && echo -e "IPv6     : ${IPV6_VAL} → gw ${GW_IPV6}"
    echo -e "Hardware : ${RAM} MB RAM / ${CPU} Cores (cpu=${CPU_TYPE}${STORAGE_SSD_FLAG:+, ssd=1})"

    read -p "[OK] ¿Desplegar VM ahora? (s/N): " CONFIRM

    case "${CONFIRM,,}" in
        s|si|sí) ;;
        *)
            echo -e "${YELLOW}Operación cancelada.${NC}"
            SUCCESS=true
            exit 0
            ;;
    esac
    
    return 0
}

# ==============================================================================
# ==============================================================================
# FASE 8: GENERACIÓN YAML
# ==============================================================================
generate_yaml() {
    echo -e "\n${BLUE}==> Generando archivo de configuración Cloud-Init (${OS_TYPE})...${NC}"

    ( umask 077 && : > "$YAML_FILE" )

    cat > "$YAML_FILE" << EOF
#cloud-config
hostname: ${NOMBRE,,}
fqdn: ${NOMBRE,,}.internal
manage_etc_hosts: true
timezone: America/Guayaquil
locale: en_US.UTF-8

growpart:
  mode: auto
  devices: ['/']

ssh_pwauth: ${SSH_PWAUTH}

users:
  - name: root
    lock_passwd: false
EOF

    if [ ${#SSH_KEYS[@]} -gt 0 ]; then
        echo "    ssh_authorized_keys:" >> "$YAML_FILE"
        for key in "${SSH_KEYS[@]}"; do
            echo "      - ${key}" >> "$YAML_FILE"
        done
    fi

    if [[ -n "$ROOT_PASS_HASH" ]]; then
        cat >> "$YAML_FILE" << EOF

chpasswd:
  expire: false
  users:
    - name: root
      password: '${ROOT_PASS_HASH}'
      type: hash
EOF
    fi

    if [ "$IPV6_CONFIGURED" = true ]; then
        cat >> "$YAML_FILE" << EOF

write_files:
  - path: /etc/sysctl.d/99-ipv6-static.conf
    content: |
      net.ipv6.conf.all.accept_ra = 0
      net.ipv6.conf.all.autoconf = 0
      net.ipv6.conf.default.accept_ra = 0
      net.ipv6.conf.default.autoconf = 0
    permissions: '0644'
EOF
    fi

    cat >> "$YAML_FILE" << EOF

package_update: true
package_upgrade: true
EOF

    # ==================== PACKAGES SEGÚN OS ====================
    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        cat >> "$YAML_FILE" << EOF

packages:
  - qemu-guest-agent
  - curl
  - htop
EOF
    else
        cat >> "$YAML_FILE" << EOF

packages:
  - qemu-guest-agent
  - curl
  - htop
  - resolvconf
EOF
    fi

    # ==================== RUNCMD SEGÚN OS ====================
    # Fragmentos IPv6/on-link para el override de netplan (evita que la IPv6
    # y la ruta on-link de un /32 se pierdan en el siguiente reinicio, ya que
    # netplan reemplaza por completo listas como addresses/routes del mismo
    # dispositivo cuando hay varios archivos .yaml definiéndolo).
    NP_ADDR_EXTRA=""; NP_ROUTE_EXTRA=""; NP_ONLINK=""
    if [ "$IPV6_CONFIGURED" = true ]; then
        NP_ADDR_EXTRA=$'\n            - '"${IPV6_VAL}"
        [ -n "$GW_IPV6" ] && NP_ROUTE_EXTRA=$'\n            - to: ::/0\n              via: '"${GW_IPV6}"
    fi
    [ "$IPV4_CIDR" -eq 32 ] && NP_ONLINK=$'\n              on-link: true'

    if [[ "$OS_TYPE" == "ubuntu" ]]; then
        # bootcmd corre en CADA arranque: envolver en cloud-init-per instance
        # para que el resolv.conf temporal (DNS durante la fase de paquetes)
        # solo se escriba en el primer boot y no pise en cada reinicio el
        # symlink a systemd-resolved que configura runcmd.
        cat >> "$YAML_FILE" << EOF

bootcmd:
  - |
    cloud-init-per instance deploy-dns sh -c 'rm -f /etc/resolv.conf; for ns in ${DNS_SERVERS}; do echo "nameserver \$ns" >> /etc/resolv.conf; done'

runcmd:
  - test -f /etc/sysctl.d/99-ipv6-static.conf && sysctl -p /etc/sysctl.d/99-ipv6-static.conf || true
  - systemctl enable --now qemu-guest-agent || true
  - mkdir -p /etc/systemd/resolved.conf.d
  - |
    cat > /etc/systemd/resolved.conf.d/dns.conf << DNSEOF
    [Resolve]
    DNS=${DNS_SERVERS}
    FallbackDNS=
    DNSStubListener=no
    DNSEOF
  - systemctl restart systemd-resolved
  - ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  - |
    cat > /etc/netplan/99-cloud-init-override.yaml << NPEOF
    network:
      version: 2
      ethernets:
        nic0:
          match:
            macaddress: "${VM_MAC}"
          dhcp4: false
          accept-ra: false
          addresses:
            - ${IPV4_VAL}/${IPV4_CIDR}${NP_ADDR_EXTRA}
          routes:
            - to: default
              via: ${GW_IPV4}${NP_ONLINK}${NP_ROUTE_EXTRA}
          nameservers:
            addresses: [${DNS_SERVERS// /, }]
    NPEOF
    chmod 600 /etc/netplan/99-cloud-init-override.yaml
  - |
    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    chmod 0755 /run/sshd
    cat > /etc/ssh/sshd_config.d/60-deploy.conf <<SSHD
    PermitRootLogin ${PERMIT_ROOT_LOGIN}
    PasswordAuthentication ${SSHD_PASSWORD_AUTH}
    PubkeyAuthentication yes
    SSHD
    chmod 644 /etc/ssh/sshd_config.d/60-deploy.conf
    sshd -t && systemctl reset-failed ssh && systemctl restart ssh
EOF
    else
        # Igual que en Ubuntu: solo el primer boot (en Debian resolvconf
        # gestiona /etc/resolv.conf después del deploy).
        cat >> "$YAML_FILE" << EOF

bootcmd:
  - |
    cloud-init-per instance deploy-dns sh -c 'rm -f /etc/resolv.conf; for ns in ${DNS_SERVERS}; do echo "nameserver \$ns" >> /etc/resolv.conf; done'

runcmd:
  - test -f /etc/sysctl.d/99-ipv6-static.conf && sysctl -p /etc/sysctl.d/99-ipv6-static.conf || true
  - systemctl enable --now qemu-guest-agent || true
  - systemctl disable --now systemd-resolved 2>/dev/null || true
  - |
    rm -f /etc/resolv.conf
    for ns in ${DNS_SERVERS}; do echo "nameserver \$ns" >> /etc/resolv.conf; done
  - mkdir -p /etc/resolvconf/resolv.conf.d
  - cp /etc/resolv.conf /etc/resolvconf/resolv.conf.d/head
  - resolvconf -u 2>/dev/null || true
  - |
    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    chmod 0755 /run/sshd
    cat > /etc/ssh/sshd_config.d/60-deploy.conf <<SSHD
    PermitRootLogin ${PERMIT_ROOT_LOGIN}
    PasswordAuthentication ${SSHD_PASSWORD_AUTH}
    PubkeyAuthentication yes
    SSHD
    chmod 644 /etc/ssh/sshd_config.d/60-deploy.conf
    sshd -t && systemctl reset-failed ssh && systemctl restart ssh
EOF
    fi

    # Distinguir "PyYAML no instalado" (saltar validación) de "YAML inválido"
    # (abortar) — antes un python3 sin python3-yaml abortaba con falso error.
    if command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('${YAML_FILE}'))" 2>/dev/null; then
            echo -e "  ${GREEN}[OK] YAML generado y validado correctamente por Python.${NC}"
        else
            echo -e "${RED}[ERROR] El YAML generado tiene errores de sintaxis.${NC}"; exit 1
        fi
    fi
}
# FASE 8b: GENERACIÓN NETWORK-CONFIG v2 (solo cuando hace falta)
# ==============================================================================
# El snippet de red rompe la pestana Cloud-Init del panel: cuando existe
# `cicustom ...,network=`, Proxmox entrega el snippet y DESCARTA ipconfig0, que
# es lo unico que escribe esa pestana. Asi que solo se usa donde el generador
# nativo se queda corto:
#   - /32: el network-config v1 de Proxmox no tiene 'on-link' y sin el netplan
#     no instala la ruta por defecto si el gateway cae fuera de la subred.
#   - IPv6 estatico: hace falta accept-ra:false o el SLAAC pelea con la fija.
# En el resto la config nativa es equivalente (tambien empareja por MAC, que es
# lo que arreglo el bug de portabilidad de la v8).
net_snippet_needed() {
    [ "${IPV4_CIDR:-24}" -eq 32 ] || [ "${IPV6_CONFIGURED:-false}" = true ]
}
# ==============================================================================
generate_network_yaml() {
    if ! net_snippet_needed; then
        NETWORK_YAML_FILE=""
        echo -e "\n${GREEN}[OK] Red estandar: se usa la config nativa de Proxmox${NC}"
        echo -e "     (sin snippet -> la pestana Cloud-Init del panel SI funciona)"
        return 0
    fi
    echo -e "\n${BLUE}==> Generando network-config v2 para Cloud-Init...${NC}"
    local WHY=""
    if [ "$IPV4_CIDR" -eq 32 ]; then WHY="/32 on-link"; fi
    if [ "$IPV6_CONFIGURED" = true ]; then
        if [ -n "$WHY" ]; then WHY="${WHY} + "; fi
        WHY="${WHY}IPv6 estatico"
    fi
    echo -e "     (necesario aqui: ${WHY})"

    ( umask 077 && : > "$NETWORK_YAML_FILE" )

    # Determinar si necesitamos on-link (gateway en otra subred, típico con /32)
    local ONLINK_FLAG=""
    if [ "$IPV4_CIDR" -eq 32 ]; then
        ONLINK_FLAG="        on-link: true"
        echo -e "  ${YELLOW}[AVISO] Detectada máscara /32: activando on-link para gateway${NC}"
    fi

    cat > "$NETWORK_YAML_FILE" << NETEOF
version: 2
ethernets:
  nic0:
    match:
      macaddress: "${VM_MAC}"
    accept-ra: false
    addresses:
      - ${IPV4_VAL}/${IPV4_CIDR}
NETEOF

    # Agregar IPv6 si está configurado
    if [ "$IPV6_CONFIGURED" = true ]; then
        echo "      - ${IPV6_VAL}" >> "$NETWORK_YAML_FILE"
    fi

    # Nameservers
    cat >> "$NETWORK_YAML_FILE" << NETEOF
    nameservers:
      addresses:
NETEOF
    for ns in $DNS_SERVERS; do
        echo "        - ${ns}" >> "$NETWORK_YAML_FILE"
    done

    # Rutas
    cat >> "$NETWORK_YAML_FILE" << NETEOF
    routes:
      - to: default
        via: ${GW_IPV4}
NETEOF

    # Agregar on-link si es necesario
    if [ -n "$ONLINK_FLAG" ]; then
        echo "$ONLINK_FLAG" >> "$NETWORK_YAML_FILE"
    fi

    # Ruta IPv6 si aplica
    if [ "$IPV6_CONFIGURED" = true ] && [ -n "$GW_IPV6" ]; then
        cat >> "$NETWORK_YAML_FILE" << NETEOF
      - to: ::/0
        via: ${GW_IPV6}
NETEOF
    fi

    echo -e "  ${GREEN}[OK] Network-config v2 generado correctamente.${NC}"
}

# FASE 9: DESPLIEGUE CON SISTEMA DE LOGS
# ==============================================================================
deploy_vm() {
    echo -e "\n${YELLOW}==> Desplegando VM ${VMID} en Proxmox...${NC}"
    echo -e "${CYAN}==> Guardando log de ejecución en: ${LOG_FILE}${NC}"

    echo "==========================================================" > "$LOG_FILE"
    echo "  LOG DE DESPLIEGUE PROXMOX - VM $VMID - $(date)" >> "$LOG_FILE"
    echo "==========================================================" >> "$LOG_FILE"

    IPCONFIG="ip=${IPV4_VAL}/${IPV4_CIDR},gw=${GW_IPV4}"
    [ "$IPV6_CONFIGURED" = true ] && IPCONFIG="${IPCONFIG},ip6=${IPV6_VAL},gw6=${GW_IPV6}"

    # OJO: nada de $(...) dentro de la asignacion de IP_CHANGE_NOTE. Bajo
    # set -e el estado de una asignacion es el de su ultima sustitucion, asi
    # que un simple test que da falso aborta el despliegue entero. El motivo
    # se calcula antes, con if.
    local IP_CHANGE_NOTE NEED_REASON=""
    if [ "$IPV4_CIDR" -eq 32 ]; then NEED_REASON="IPv4 /32"; fi
    if [ "$IPV6_CONFIGURED" = true ]; then
        if [ -n "$NEED_REASON" ]; then NEED_REASON="${NEED_REASON} + "; fi
        NEED_REASON="${NEED_REASON}IPv6 estatico"
    fi
    if net_snippet_needed; then
        IP_CHANGE_NOTE="## 🛠️ Como cambiar la IP

> Esta VM lleva snippet de red (\`cicustom\`) porque su configuracion lo exige
> (${NEED_REASON}), y por eso Proxmox **descarta** el campo
> **Cloud-Init -> IP Config** del panel: cambiarlo ahi no hace nada.
> Usa \`deploy-vm.sh --cambiar-ip ${VMID}\` en el nodo."
    else
        IP_CHANGE_NOTE="## 🛠️ Como cambiar la IP

> Esta VM usa la configuracion nativa de Proxmox, asi que la pestana
> **Cloud-Init -> IP Config** del panel **si funciona**: cambia la IP, pulsa
> *Regenerate Image* y **apaga y enciende** la VM (un reboot no vale, el disco
> cloud-init se adjunta al arrancar).
> Tambien vale \`deploy-vm.sh --cambiar-ip ${VMID}\` en el nodo."
    fi

    local NET_QUEUES=""
    (( CPU > 1 )) && NET_QUEUES=",queues=${CPU}"

    # Notas de la VM: Proxmox renderiza Markdown en el panel Notes — se
    # documenta TODO lo usado en el despliegue, legible de un vistazo.
    local AUTH_DESC
    case "$AUTH_MODE" in
        1) AUTH_DESC="root + contraseña" ;;
        2) AUTH_DESC="solo clave SSH (${#SSH_KEYS[@]} clave/s — password deshabilitado)" ;;
        3) AUTH_DESC="clave SSH (${#SSH_KEYS[@]} clave/s) + contraseña root" ;;
    esac

    local VM_DESCRIPTION="# ${NOMBRE}  ·  VM ${VMID}

**${OS_PRETTY}**

## 🌐 Red

- **IPv4:** \`${IPV4_VAL}/${IPV4_CIDR}\`  →  gateway ${GW_IPV4}"
    [ "$IPV6_CONFIGURED" = true ] && VM_DESCRIPTION="${VM_DESCRIPTION}
- **IPv6:** \`${IPV6_VAL}\`  →  gateway ${GW_IPV6}"
    VM_DESCRIPTION="${VM_DESCRIPTION}
- **Bridge:** ${BRIDGE}${VLAN_TAG:+  ·  VLAN ${VLAN_TAG#,tag=}}
- **MAC net0:** \`${VM_MAC}\`  (interfaz emparejada por MAC)
- **DNS:** ${DNS_SERVERS}

## ⚙️ Hardware

- **CPU:** ${CPU} core(s)  ·  tipo \`${CPU_TYPE}\`${NET_QUEUES:+  ·  red multiqueue}
- **RAM:** ${RAM} MB
- **Disco:** ${DISK} GB en **${STORAGE_IMG}**${STORAGE_SSD_FLAG:+  ·  SSD (discard/TRIM)}

## 💿 Sistema

- **SO:** ${OS_PRETTY}
- **Imagen oficial:** ${IMAGE_NAME}
- **Hostname:** \`${NOMBRE,,}.internal\`  ·  zona horaria America/Guayaquil
- **Acceso:** ${AUTH_DESC}

---
${IP_CHANGE_NOTE}

---
📅 Desplegado: $(date '+%Y-%m-%d %H:%M')  ·  deploy-vm.sh v8.3
📝 Log: ${LOG_FILE}"

    local CICUSTOM_ARG="user=${STORAGE_SNIP}:snippets/user-data-${VMID}.yaml"
    net_snippet_needed && CICUSTOM_ARG="${CICUSTOM_ARG},network=${STORAGE_SNIP}:snippets/network-data-${VMID}.yaml"

    {
        echo "[1/3] Creando estructura base de la VM..."
        qm create "$VMID" \
          --name "$NOMBRE" \
          --memory "$RAM" \
          --cores "$CPU" \
          --net0 "virtio=${VM_MAC},bridge=${BRIDGE}${VLAN_TAG:-}${NET_QUEUES}" \
          --ipconfig0 "$IPCONFIG" \
          --nameserver "$DNS_SERVERS" \
          --scsihw virtio-scsi-single \
          --scsi0 "${STORAGE_IMG}:0,import-from=${FILE_PATH},discard=on,iothread=1${STORAGE_SSD_FLAG}" \
          --ide2 "${STORAGE_IMG}:cloudinit" \
          --boot "order=scsi0" \
          --cpu "${CPU_TYPE}" \
          --ostype l26 \
          --agent enabled=1 \
          --onboot 1 \
          --serial0 socket \
          --vga serial0 \
          --description "$VM_DESCRIPTION" \
          --cicustom "$CICUSTOM_ARG"

        echo -e "\n[2/3] Redimensionando el disco duro..."
        qm resize "$VMID" scsi0 "${DISK}G"
        
        echo -e "\n[3/3] Iniciando la Máquina Virtual..."
        qm start "$VMID"
    } >> "$LOG_FILE" 2>&1

    echo -e "\n${BLUE}==> Esperando a que el Guest Agent responda (cloud-init terminó)...${NC}"
    # 600s: con package_upgrade=true y un mirror lento, 300s daba falsos
    # "revisa cloud-init manualmente" en VMs que terminaban bien.
    local WAIT_MAX=600 WAITED=0
    while (( WAITED < WAIT_MAX )); do
        if qm guest cmd "$VMID" ping &>/dev/null; then
            echo -e "${GREEN}[OK] Guest Agent activo tras ${WAITED}s.${NC}"
            break
        fi
        sleep 5
        WAITED=$((WAITED+5))
        printf "."
    done
    if (( WAITED >= WAIT_MAX )); then
        echo -e "\n${YELLOW}[AVISO] Guest Agent no respondió en ${WAIT_MAX}s. La VM arrancó pero revisa cloud-init manualmente.${NC}"
    fi

    SUCCESS=true

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ [OK] VM ${VMID} creada y arrancada exitosamente       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Terminal : qm terminal ${VMID}"
    echo -e "${CYAN}Acceso   : ssh root@${IPV4_VAL}"
    echo -e "${CYAN}Log      : ${LOG_FILE}${NC}\n"

    if net_snippet_needed; then
        echo -e "${YELLOW}[AVISO] Esta VM lleva snippet de red (lo exige su /32 o su IPv6), asi que${NC}"
        echo -e "${YELLOW}        la pestana Cloud-Init del panel NO le aplica la IP.${NC}"
        echo -e "${YELLOW}        Para cambiarla:  $0 --cambiar-ip ${VMID}${NC}\n"
    else
        echo -e "${CYAN}Cambiar IP: la pestana Cloud-Init del panel funciona en esta VM"
        echo -e "            (cambiar -> Regenerate Image -> apagar y encender),"
        echo -e "            o bien:  $0 --cambiar-ip ${VMID}${NC}\n"
    fi
}


# ==============================================================================
# MODO --cambiar-ip: reconfigurar la red de una VM YA existente
# ==============================================================================
show_help() {
    cat <<'AYUDA'
deploy-vm.sh v8.3 - instalador de VMs Proxmox por cloud-init

  deploy-vm.sh                      Despliegue interactivo de una VM nueva.
  deploy-vm.sh --cambiar-ip <VMID>  Cambia la IP/gateway de una VM ya creada.
  deploy-vm.sh --help               Esta ayuda.

POR QUE HACE FALTA --cambiar-ip
  Las VMs creadas por este script usan `cicustom` con un snippet de red. Cuando
  ese snippet existe, Proxmox lo entrega y DESCARTA el campo "IP Config (net0)"
  de la pestana Cloud-Init: cambiarlo ahi no tiene ningun efecto, y no da error.
  Ademas el instance-id se calcula de la config de Proxmox y NO del snippet, asi
  que editar el .yaml a mano tampoco basta: cloud-init se cree ya aprovisionado
  y deja el netplan como estaba. --cambiar-ip hace la secuencia completa.
AYUDA
}

# Ruta real del directorio de snippets de un storage dado.
snippet_dir_for_storage() {
    local st="$1" base
    base=$(pvesh get "/storage/${st}" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("path",""))' 2>/dev/null || true)
    [ -z "$base" ] && base=$(awk "/^dir: ${st}\$/{f=1;next} f&&/^\\s*path /{print \$2;exit}" /etc/pve/storage.cfg 2>/dev/null)
    [ -z "$base" ] && base="/var/lib/vz"
    echo "${base}/snippets"
}

CHIP_BACKUP=""
change_ip_rollback() {
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    set +e
    echo -e "\n${RED}[ERROR] Fallo al cambiar la IP.${NC}"
    if [ -n "$CHIP_BACKUP" ] && [ -f "$CHIP_BACKUP" ]; then
        tar xzf "$CHIP_BACKUP" -C / 2>/dev/null \
            && echo -e "${YELLOW}==> Snippets restaurados desde ${CHIP_BACKUP}${NC}"
    fi
    echo -e "${YELLOW}==> La VM NO se ha destruido. Revisa y reintenta.${NC}"
    exit 1
}

change_vm_ip() {
    # PRIMERO de todo: el trap del despliegue hace `qm destroy $VMID --purge`
    # ante cualquier error o Ctrl+C. Aqui trabajamos sobre una VM existente CON
    # DATOS, asi que se desarma antes de tocar nada y se pone uno que solo
    # restaura los snippets.
    # Se queda SIN trap durante las validaciones (todavia no hay nada que
    # revertir); el de restauracion se arma justo despues del respaldo.
    trap - INT TERM ERR EXIT

    local id="$1"
    [ -z "$id" ] && { echo -e "${RED}[ERROR] Falta el VMID. Uso: $0 --cambiar-ip <VMID>${NC}"; exit 1; }
    [[ "$id" =~ ^[0-9]+$ ]] || { echo -e "${RED}[ERROR] VMID invalido: ${id}${NC}"; exit 1; }
    qm config "$id" &>/dev/null || { echo -e "${RED}[ERROR] La VM ${id} no existe en este nodo.${NC}"; exit 1; }

    local conf vmname
    conf=$(qm config "$id")
    vmname=$(awk -F': ' '/^name:/{print $2}' <<< "$conf")
    echo -e "\n${BLUE}==> Cambiar red de la VM ${id} (${vmname})${NC}"

    # El snippet hace match por MAC: si no es la del net0, netplan no aplica nada.
    VM_MAC=$(grep -oP '^net0:.*?virtio=\K[0-9A-Fa-f:]{17}' <<< "$conf" || true)
    [ -z "$VM_MAC" ] && { echo -e "${RED}[ERROR] No se pudo leer la MAC de net0.${NC}"; exit 1; }

    # La VM puede estar en cualquiera de los dos modos: con snippet de red
    # (manda el .yaml) o sin el (manda ipconfig0). Se detecta, y segun lo que
    # pida la configuracion NUEVA se migra de un modo al otro.
    local cic userref netref HAD_SNIPPET=false
    cic=$(awk -F': ' '/^cicustom:/{print $2}' <<< "$conf" || true)
    userref=$(grep -oP 'user=\K[^,]+' <<< "$cic" || true)
    netref=$(grep -oP 'network=\K[^,]+' <<< "$cic" || true)
    [ -n "$netref" ] && HAD_SNIPPET=true

    local snipstore="${netref%%:*}"
    [ -z "$snipstore" ] && snipstore="${userref%%:*}"
    [ -z "$snipstore" ] && snipstore="local"
    SNIPPET_FULL_PATH=$(snippet_dir_for_storage "$snipstore")
    NETWORK_YAML_FILE="${SNIPPET_FULL_PATH}/network-data-${id}.yaml"

    echo -e "\n${CYAN}--- Configuracion actual (la que de verdad se aplica) ---${NC}"
    if [ "$HAD_SNIPPET" = true ] && [ -f "$NETWORK_YAML_FILE" ]; then
        echo -e "  origen: snippet de red (${NETWORK_YAML_FILE})"
        grep -E '^\s+(- [0-9a-fA-F]|addresses:|via:|on-link:)' "$NETWORK_YAML_FILE" || true
    else
        echo -e "  origen: configuracion nativa de Proxmox (ipconfig0)"
        awk -F': ' '/^ipconfig0:/{print "  "$2}' <<< "$conf"
    fi
    echo -e "${CYAN}---------------------------------------------------------${NC}"

    # ---- nueva IPv4 ----
    while true; do
        read -p "Nueva IPv4 (formato IP/CIDR, ej. 192.0.2.10/24): " NEW_IP
        IPV4_VAL="${NEW_IP%%/*}"; IPV4_CIDR="${NEW_IP##*/}"
        if [ "$NEW_IP" = "$IPV4_VAL" ]; then
            echo -e "${RED}[ERROR] Falta el prefijo (/24, /32...).${NC}"; continue
        fi
        valid_ipv4 "$IPV4_VAL" && valid_cidr "$IPV4_CIDR" && break
        echo -e "${RED}[ERROR] IP o prefijo invalidos.${NC}"
    done
    while true; do
        read -p "Gateway IPv4: " GW_IPV4
        valid_ipv4 "$GW_IPV4" && break
        echo -e "${RED}[ERROR] Gateway invalido.${NC}"
    done
    [ "$IPV4_CIDR" -eq 32 ] && echo -e "${YELLOW}[AVISO] /32: se activara on-link para el gateway.${NC}"

    # ---- IPv6 opcional ----
    IPV6_CONFIGURED=false; IPV6_VAL=""; GW_IPV6=""
    read -p "IPv6 (Enter para omitir, ej. 2001:db8::10/64): " NEW_IP6
    if [ -n "$NEW_IP6" ]; then
        IPV6_VAL="$NEW_IP6"; IPV6_CONFIGURED=true
        read -p "Gateway IPv6 (Enter para omitir): " GW_IPV6
    fi

    # ---- DNS: se conserva el de la VM ----
    DNS_SERVERS=$(awk -F': ' '/^nameserver:/{print $2}' <<< "$conf" || true)
    [ -z "$DNS_SERVERS" ] && DNS_SERVERS="8.8.8.8 1.1.1.1"

    echo -e "\n${YELLOW}==> Se aplicara a la VM ${id}: ${IPV4_VAL}/${IPV4_CIDR} gw ${GW_IPV4}${NC}"
    echo -e "${YELLOW}    Implica APAGAR y ENCENDER la VM (no vale reboot).${NC}"
    read -p "Confirmas? (s/N): " OK
    [[ "$OK" =~ ^[sS]$ ]] || { echo "Cancelado."; trap - EXIT; exit 0; }

    mkdir -p /root/backups
    CHIP_BACKUP="/root/backups/pre-cambiar-ip-${id}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$CHIP_BACKUP" $([ -f "$NETWORK_YAML_FILE" ] && echo "$NETWORK_YAML_FILE") \
        "/etc/pve/qemu-server/${id}.conf" 2>/dev/null || true
    echo -e "${GREEN}[OK] Respaldo: ${CHIP_BACKUP}${NC}"
    trap change_ip_rollback EXIT

    # 1) dejar la VM en el modo que exige la configuracion NUEVA
    local CIC_NEW="user=${userref}"
    if net_snippet_needed; then
        generate_network_yaml
        CIC_NEW="${CIC_NEW},network=${snipstore}:snippets/network-data-${id}.yaml"
        if [ "$HAD_SNIPPET" = false ]; then
            echo -e "${YELLOW}[AVISO] La nueva config exige snippet de red, asi que a partir de${NC}"
            echo -e "${YELLOW}        ahora la pestana Cloud-Init del panel dejara de aplicar la IP.${NC}"
        fi
    else
        rm -f "$NETWORK_YAML_FILE"
        NETWORK_YAML_FILE=""
        if [ "$HAD_SNIPPET" = true ]; then
            echo -e "${GREEN}[OK] La nueva config no necesita snippet: se retira, y la pestana${NC}"
            echo -e "${GREEN}     Cloud-Init del panel vuelve a funcionar en esta VM.${NC}"
        fi
    fi
    [ -n "$userref" ] && qm set "$id" --cicustom "$CIC_NEW" >/dev/null

    # 2) ipconfig0: es la fuente real cuando NO hay snippet, y cuando lo hay
    #    evita que el panel muestre datos falsos. En ambos casos hace que
    #    cambie el instance-id, que es lo que obliga a cloud-init a reaplicar.
    IPCONFIG="ip=${IPV4_VAL}/${IPV4_CIDR},gw=${GW_IPV4}"
    [ "$IPV6_CONFIGURED" = true ] && [ -n "$GW_IPV6" ] && IPCONFIG="${IPCONFIG},ip6=${IPV6_VAL},gw6=${GW_IPV6}"
    qm set "$id" --ipconfig0 "$IPCONFIG" >/dev/null

    # 3) regenerar el disco cloud-init
    qm cloudinit update "$id" >/dev/null

    # 4) forzar el reaprovisionamiento dentro del invitado: sin esto cloud-init
    #    ve el mismo estado y NO reescribe /etc/netplan/50-cloud-init.yaml
    if qm status "$id" 2>/dev/null | grep -q running; then
        echo -e "${BLUE}==> Limpiando estado de cloud-init dentro de la VM...${NC}"
        qm guest exec "$id" --timeout 60 -- /bin/sh -c 'cloud-init clean --logs' >/dev/null 2>&1 \
            || echo -e "${YELLOW}[AVISO] No se pudo ejecutar 'cloud-init clean' (agente invitado?).${NC}"
        echo -e "${BLUE}==> Apagando la VM...${NC}"
        qm stop "$id" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do qm status "$id" 2>/dev/null | grep -q stopped && break; sleep 2; done
    fi

    echo -e "${BLUE}==> Arrancando la VM...${NC}"
    qm start "$id" >/dev/null

    # 5) comprobar contra el invitado, que es la unica fuente fiable
    echo -e "${BLUE}==> Verificando la IP dentro de la VM...${NC}"
    local got=""
    for _ in $(seq 1 45); do
        got=$(qm guest cmd "$id" network-get-interfaces 2>/dev/null \
              | grep -o '"ip-address" : "[^"]*"' | cut -d'"' -f4 | grep -x "$IPV4_VAL" || true)
        [ -n "$got" ] && break
        sleep 5
    done

    SUCCESS=true
    trap - EXIT
    if [ -n "$got" ]; then
        echo -e "\n${GREEN}[OK] La VM ${id} responde con ${IPV4_VAL}.${NC}"
    else
        echo -e "\n${YELLOW}[AVISO] La VM arranco pero el agente aun no reporta ${IPV4_VAL}.${NC}"
        echo -e "${YELLOW}        Comprueba con: qm guest cmd ${id} network-get-interfaces${NC}"
        echo -e "${YELLOW}        Respaldo por si hay que volver atras: ${CHIP_BACKUP}${NC}"
    fi
}

# ==============================================================================
# EJECUCIÓN PRINCIPAL
# ==============================================================================
case "$MODE" in
    help)      trap - INT TERM ERR EXIT; show_help ;;
    change-ip) change_vm_ip "$TARGET_VMID" ;;
    deploy)
        select_os_and_download
        detect_cpu_type
        auto_select_image_storage
        ask_snippet_storage
        ask_vmid_and_name
        ask_auth_mode
        ask_network
        ask_resources
        confirm_deployment
        generate_yaml
        generate_network_yaml
        deploy_vm
        ;;
esac
