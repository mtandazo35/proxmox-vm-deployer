#!/bin/bash
# ==============================================================================
# Cloud-Init Proxmox - Instalador Modular V8.1
# Cambios 8.0: red por MAC fija (OUI Proxmox) en vez de match por driver/nombre
# Cambios 8.1: set -E + trap EXIT (rollback cubre fallos dentro de funciones),
# checksum por nombre remoto (Ubuntu nunca se verificaba), validación AUTH_MODE/
# claves SSH/DNS/VLAN/índice storage, disco mínimo = tamaño virtual de la imagen,
# pvesm set preserva content real, VMID chequeado a nivel cluster, descarga a
# .part, MAC sin colisiones, bootcmd once-per-instance, netplan 600, timeout 600s
# ==============================================================================

set -Eeuo pipefail

# ==================== GLOBALES Y COLORES ====================
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

IMAGE_URL=""; IMAGE_NAME=""; FILE_PATH=""; CHECKSUM_URL=""; CHECKSUM_ALGO=""
STORAGE_IMG=""; STORAGE_SNIP=""; SNIPPET_FULL_PATH=""
VMID=""; NOMBRE=""; RAM=""; CPU=""; DISK=""
AUTH_MODE=""; ROOT_PASS_HASH=""; SSH_PWAUTH="false"; SSHD_PASSWORD_AUTH="no"; SSH_KEYS=()
BRIDGE=""; VLAN_TAG=""; IPV4_VAL=""; IPV4_CIDR=""; GW_IPV4=""
IPV6_CONFIGURED=false; GW_IPV6=""; DNS_SERVERS=""
OS_TYPE="debian"; OS_PRETTY=""
CPU_TYPE="host"; STORAGE_SSD_FLAG=""
SUCCESS=false; ROLLBACK_EXECUTED=false; LOG_FILE=""; NETWORK_YAML_FILE=""; YAML_FILE=""
VM_MAC=""; IMG_MIN_GB="2"; PERMIT_ROOT_LOGIN=""

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

# ==================== FUNCIONES DE DETECCIÓN (GENÉRICO PARA CUALQUIER NODO) ====================
# Elige el tipo de CPU según si el nodo es standalone o pertenece a un cluster:
# "host" da el máximo rendimiento pero fija la VM a la CPU exacta del nodo (rompe
# migración en vivo si el cluster tiene hardware distinto entre nodos). En cluster
# usamos un baseline portable con AES-NI (relevante para VPN/TLS/DNS-over-TLS).
detect_cpu_type() {
    if [ -f /etc/pve/corosync.conf ]; then
        CPU_TYPE="x86-64-v2-AES"
        echo -e "  ${CYAN}ℹ️  Nodo en cluster detectado → cpu=${CPU_TYPE} (portable, compatible con migración en vivo)${NC}"
    else
        CPU_TYPE="host"
        echo -e "  ${CYAN}ℹ️  Nodo standalone detectado → cpu=${CPU_TYPE} (máximo rendimiento)${NC}"
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
        echo -e "\n${YELLOW}⏹️  Instalación abortada. No se hicieron cambios en el nodo.${NC}"
        exit 1
    fi

    echo -e "\n${RED}❌ CANCELACIÓN/ERROR - Limpiando recursos parciales de la VM ${VMID}...${NC}"

    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}📝 Revisa el archivo de log para ver el error exacto: ${LOG_FILE}${NC}"
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
    echo -e "${GREEN}║    Cloud-Init Proxmox - Despliegue Automatizado      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${BLUE}🐧 Selecciona el Sistema Operativo Base:${NC}"
    echo "  1) Debian 12 (Bookworm)"
    echo "  2) Debian 13 (Trixie)"
    echo "  3) Ubuntu 20.04 LTS (Focal Fossa)"
    echo "  4) Ubuntu 22.04 LTS (Jammy Jellyfish)"
    echo "  5) Ubuntu 24.04 LTS (Noble Numbat)"
    
    read -p "Opción [1]: " OS_OPT; OS_OPT=${OS_OPT:-1}

    case "$OS_OPT" in
        1)
            IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
            IMAGE_NAME="debian-12-genericcloud-amd64.qcow2"
            OS_PRETTY="Debian 12 (Bookworm)"
            CHECKSUM_URL="https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
            CHECKSUM_ALGO="sha512sum"
            OS_TYPE="debian"
            ;;
        2)
            IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
            IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
            OS_PRETTY="Debian 13 (Trixie)"
            CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
            CHECKSUM_ALGO="sha512sum"
            OS_TYPE="debian"
            ;;
        3)
            IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-20.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 20.04 LTS (Focal)"
            CHECKSUM_URL="https://cloud-images.ubuntu.com/focal/current/SHA256SUMS"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        4)
            IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-22.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 22.04 LTS (Jammy)"
            CHECKSUM_URL="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        5)
            IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
            IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
            OS_PRETTY="Ubuntu 24.04 LTS (Noble)"
            CHECKSUM_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
            CHECKSUM_ALGO="sha256sum"
            OS_TYPE="ubuntu"
            ;;
        *)
            echo -e "${RED}❌ Opción inválida.${NC}"; exit 1
            ;;
    esac

    FILE_PATH="/var/lib/vz/template/iso/$IMAGE_NAME"
    mkdir -p "/var/lib/vz/template/iso"

    echo -e "\n${BLUE}🔍 Verificando conectividad y caché de imagen...${NC}"
    if ! wget -q --spider --timeout=5 "https://8.8.8.8" &>/dev/null && ! ping -c 1 8.8.8.8 &>/dev/null; then
         echo -e "${RED}❌ Sin conexión a Internet en el nodo Proxmox.${NC}"; exit 1
    fi

    # Descarga (con posible re-descarga automática si el checksum no matchea el cache)
    # Descargar a .part y renombrar al terminar: una descarga interrumpida
    # jamás queda en caché como si fuera una imagen completa.
    local FRESHLY_DOWNLOADED=false
    if [ ! -f "$FILE_PATH" ]; then
        echo -e "${YELLOW}📥 Descargando imagen oficial ($IMAGE_NAME)...${NC}"
        if ! wget -q --show-progress --tries=3 --timeout=30 --continue -O "${FILE_PATH}.part" "$IMAGE_URL"; then
            echo -e "${RED}❌ Falló la descarga. Verifica la red o la URL.${NC}"; rm -f "${FILE_PATH}.part"; exit 1
        fi
        mv "${FILE_PATH}.part" "$FILE_PATH"
        FRESHLY_DOWNLOADED=true
    else
        echo -e "${GREEN}✅ Imagen '$IMAGE_NAME' encontrada en caché local.${NC}"
    fi

    # Verificar checksum oficial (re-descarga si el cache esta desactualizado).
    # OJO: en el archivo de sumas upstream la imagen aparece con su nombre
    # ORIGINAL (ej. noble-server-cloudimg-amd64.img), no con el nombre local
    # renombrado de la caché — buscar por el basename de la URL.
    if [ -n "$CHECKSUM_URL" ]; then
        local REMOTE_NAME
        REMOTE_NAME=$(basename "$IMAGE_URL")
        local ATTEMPT=1
        while : ; do
            echo -e "${BLUE}🔐 Verificando integridad de la imagen (${CHECKSUM_ALGO}) [intento $ATTEMPT/2]...${NC}"
            local SUMS_FILE
            SUMS_FILE=$(mktemp)
            if ! wget -q --tries=3 --timeout=15 -O "$SUMS_FILE" "$CHECKSUM_URL"; then
                rm -f "$SUMS_FILE"
                echo -e "${YELLOW}⚠️  No se pudo descargar el archivo de sumas. Saltando verificación.${NC}"
                break
            fi
            local EXPECTED
            EXPECTED=$(awk -v n="$REMOTE_NAME" '$2==n || $2=="*"n {print $1; exit}' "$SUMS_FILE")
            rm -f "$SUMS_FILE"
            if [ -z "$EXPECTED" ]; then
                echo -e "${YELLOW}⚠️  No se encontró entry para '$REMOTE_NAME' en el archivo de sumas. Saltando verificación.${NC}"
                break
            fi
            local ACTUAL
            ACTUAL=$($CHECKSUM_ALGO "$FILE_PATH" | awk '{print $1}')
            if [ "$EXPECTED" = "$ACTUAL" ]; then
                echo -e "${GREEN}✅ Checksum OK (${CHECKSUM_ALGO}).${NC}"
                break
            fi

            # Mismatch
            if [ "$FRESHLY_DOWNLOADED" = true ] || [ "$ATTEMPT" -ge 2 ]; then
                # Descarga fresca y sigue fallando -> corrupta o MITM
                echo -e "${RED}❌ Checksum MISMATCH tras descarga fresca. La imagen puede estar corrupta o alterada.${NC}"
                echo -e "${RED}   Esperado: $EXPECTED${NC}"
                echo -e "${RED}   Obtenido: $ACTUAL${NC}"
                rm -f "$FILE_PATH"
                exit 1
            fi

            # Cache obsoleto: el upstream publico una nueva build -> re-descargar
            echo -e "${YELLOW}⚠️  Checksum no coincide (caché obsoleto, el upstream publicó una nueva build).${NC}"
            echo -e "${YELLOW}   Esperado: $EXPECTED${NC}"
            echo -e "${YELLOW}   En caché: $ACTUAL${NC}"
            echo -e "${YELLOW}   Re-descargando imagen...${NC}"
            # NO borrar la caché vieja todavía: si la re-descarga falla (mirror
            # caído/intermitente), conservamos la imagen anterior en vez de
            # quedarnos sin nada y re-descargar completo en la próxima corrida.
            if ! wget -q --show-progress --tries=3 --timeout=30 -O "${FILE_PATH}.part" "$IMAGE_URL"; then
                rm -f "${FILE_PATH}.part"
                echo -e "${RED}❌ Falló la re-descarga. Se conserva la imagen anterior en caché (build vieja).${NC}"
                exit 1
            fi
            mv -f "${FILE_PATH}.part" "$FILE_PATH"
            FRESHLY_DOWNLOADED=true
            ATTEMPT=$((ATTEMPT+1))
        done
    fi

    # Tamaño virtual de la imagen = disco mínimo de la VM: qm resize no puede
    # ENCOGER un disco, así que pedir menos que esto haría fallar el deploy
    # (Debian 13 genericcloud = 3G, Ubuntu noble = 3.5G...). Redondeo hacia arriba.
    if command -v qemu-img >/dev/null 2>&1; then
        local VSIZE
        VSIZE=$(qemu-img info --output=json "$FILE_PATH" 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null || true)
        if [[ "$VSIZE" =~ ^[0-9]+$ ]] && (( VSIZE > 0 )); then
            IMG_MIN_GB=$(( (VSIZE + 1073741823) / 1073741824 ))
            echo -e "  ${CYAN}ℹ️  Disco virtual de la imagen: ${IMG_MIN_GB} GB (mínimo aceptado para la VM)${NC}"
        fi
    fi
}

# ==============================================================================
# FASE 2: AUTO-SELECCIÓN DE STORAGE PARA IMÁGENES
# ==============================================================================
auto_select_image_storage() {
    echo -e "\n${BLUE}💾 Storages disponibles para el Disco Virtual:${NC}"
    mapfile -t STORAGES_IMG < <(pvesm status --content images 2>/dev/null | awk '$3=="active" {print $1}')
    
    if [ ${#STORAGES_IMG[@]} -eq 0 ]; then
        echo -e "${RED}❌ No hay storages de imágenes activos.${NC}"; exit 1
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
        echo -e "  ${GREEN}✅ Storage único seleccionado: ${CYAN}$STORAGE_IMG${NC}"
    else
        while true; do
            read -p "Selecciona storage para disco VM [1]: " IMG_IDX; IMG_IDX=${IMG_IDX:-1}
            if [[ "$IMG_IDX" =~ ^[0-9]+$ ]] && (( IMG_IDX >= 1 && IMG_IDX <= ${#STORAGES_IMG[@]} )); then
                STORAGE_IMG="${STORAGES_IMG[$((IMG_IDX-1))]}"
                break
            fi
            echo -e "${RED}❌ Índice inválido. Selecciona un número del 1 al ${#STORAGES_IMG[@]}.${NC}"
        done
        echo -e "${GREEN}✅ Storage seleccionado: ${CYAN}$STORAGE_IMG${NC}"
    fi

    local ROTA
    ROTA=$(detect_storage_rotational "$STORAGE_IMG") || true
    if [ "$ROTA" = "0" ]; then
        STORAGE_SSD_FLAG=",ssd=1"
        echo -e "  ${CYAN}ℹ️  Medio detectado: SSD/NVMe → ssd=1${NC}"
    elif [ "$ROTA" = "1" ]; then
        echo -e "  ${CYAN}ℹ️  Medio detectado: HDD rotacional → ssd=1 omitido${NC}"
    else
        echo -e "  ${CYAN}ℹ️  No se pudo determinar el tipo de medio (storage remoto/red) → ssd=1 omitido${NC}"
    fi
}

# ==============================================================================
# FASE 3: AUTO-SELECCIÓN DE STORAGE PARA SNIPPETS
# ==============================================================================
ask_snippet_storage() {
    echo -e "\n${BLUE}📄 Detectando storage para Snippets/Cloud-Init...${NC}"
    mapfile -t STORAGES_SNIP < <(pvesm status 2>/dev/null | awk '$3=="active" && $2 ~ /^(dir|nfs|cifs|cephfs)$/ {print $1}')

    if [ ${#STORAGES_SNIP[@]} -eq 0 ]; then
        echo -e "${RED}❌ No hay storages tipo dir activos para snippets.${NC}"; exit 1
    fi

    STORAGE_SNIP="${STORAGES_SNIP[0]}"
    echo -e "${GREEN}✅ Snippets en: ${CYAN}$STORAGE_SNIP${NC} (único compatible)"

    # Habilitar snippets PRESERVANDO el content real del storage. El content
    # se lee de la API (/storage/<id>), no de `pvesm status` (cuya columna 2
    # es el TIPO, no el content). Solo se AÑADE "snippets" si falta — jamás se
    # reconstruye la lista, para no borrar tipos existentes (iso, vztmpl,
    # backup, import de PVE 8.2+, etc.) de la config del nodo.
    CURRENT_CONTENT=$(pvesh get "/storage/${STORAGE_SNIP}" --output-format json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("content",""))' 2>/dev/null || true)

    if [ -n "$CURRENT_CONTENT" ]; then
        if [[ ",${CURRENT_CONTENT}," != *",snippets,"* ]]; then
            echo -e "${CYAN}🔧 Habilitando snippets en $STORAGE_SNIP (preservando: ${CURRENT_CONTENT})...${NC}"
            pvesm set "$STORAGE_SNIP" --content "${CURRENT_CONTENT},snippets" || true
        fi
    else
        # No se pudo leer el content: NO tocar la config del storage.
        echo -e "${YELLOW}⚠️  No se pudo leer el content de ${STORAGE_SNIP}; si 'snippets' no está habilitado, actívalo manualmente (Datacenter → Storage).${NC}"
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
    echo -e "\n${BLUE}🆔 Identificación de la Máquina Virtual${NC}"
    while true; do
        PROXIMO_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
        read -p "ID VM [$PROXIMO_ID]: " INPUT_VMID
        VMID=${INPUT_VMID:-$PROXIMO_ID}
        
        if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [ "$VMID" -lt 100 ]; then
            echo -e "${RED}❌ El ID debe ser un número ≥ 100.${NC}"
        elif vmid_exists "$VMID"; then
            echo -e "${RED}❌ El ID $VMID ya existe en el cluster (VM o CT, puede estar en otro nodo). Elige otro.${NC}"
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
            echo -e "${RED}❌ El nombre es obligatorio.${NC}"
        elif ! [[ "$NOMBRE" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            echo -e "${RED}❌ Nombre inválido. Usa solo letras, dígitos y '-' (1-63 chars, sin empezar/terminar con '-').${NC}"
        else
            break
        fi
    done
}

ask_resources() {
    echo -e "\n${BLUE}🖥️  Recursos de Hardware${NC}"
    
    while true; do
        read -p "RAM MB [2048]: " RAM; RAM=${RAM:-2048}
        [[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) && break || echo -e "${RED}❌ RAM inválida (mínimo 512)${NC}"
    done
    
    while true; do
        read -p "CPU cores [2]: " CPU; CPU=${CPU:-2}
        [[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 )) && break || echo -e "${RED}❌ CPU inválida (mínimo 1)${NC}"
    done
    
    while true; do
        read -p "Disco GB [20]: " DISK; DISK=${DISK:-20}
        # Mínimo = tamaño virtual de la imagen (qm resize no puede encoger)
        [[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= IMG_MIN_GB )) || { echo -e "${RED}❌ Disco mínimo ${IMG_MIN_GB}GB (la imagen ${IMAGE_NAME} no se puede encoger)${NC}"; continue; }

        local AVAIL_KB=$(pvesm status | awk -v s="$STORAGE_IMG" '$1==s {print $6}')
        if [[ -z "$AVAIL_KB" ]]; then break; fi
        local AVAIL_GB=$(( AVAIL_KB / 1048576 ))

        if (( DISK > AVAIL_GB )); then
            echo -e "${RED}❌ Espacio insuficiente. Pediste ${DISK}GB pero solo hay ${AVAIL_GB}GB libres en $STORAGE_IMG.${NC}"
        else
            echo -e "${GREEN}✅ Recursos verificados correctamente.${NC}"
            break
        fi
    done
}

# ==============================================================================
# FASE 5: AUTENTICACIÓN
# ==============================================================================
ask_auth_mode() {
    echo -e "\n${BLUE}🔐 Autenticación:${NC}"
    echo "1) Solo root + contraseña"
    echo "2) Solo clave SSH"
    echo "3) SSH + contraseña root (recomendado)"
    # Validar: un typo aquí (ej. "4") dejaba una VM SIN password y SIN claves
    # — completamente inaccesible, incluso por consola serial.
    while true; do
        read -p "Opción [3]: " AUTH_MODE; AUTH_MODE=${AUTH_MODE:-3}
        [[ "$AUTH_MODE" =~ ^[123]$ ]] && break
        echo -e "${RED}❌ Opción inválida. Debe ser 1, 2 o 3.${NC}"
    done

    if [[ "$AUTH_MODE" == "1" ]] || [[ "$AUTH_MODE" == "3" ]]; then
        while true; do
            read -s -p "Password root: " PASS1; echo
            read -s -p "Confirma: " PASS2; echo
            [[ "$PASS1" == "$PASS2" && -n "$PASS1" ]] && break
            echo -e "${RED}❌ Las contraseñas no coinciden${NC}"
        done

        if ! command -v mkpasswd >/dev/null 2>&1; then
            echo -e "${YELLOW}🔧 mkpasswd no encontrado, instalando paquete 'whois'...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whois >/dev/null 2>&1 || {
                echo -e "${RED}❌ No se pudo instalar 'whois' (requerido para hashear el password).${NC}"
                echo -e "${RED}   Ejecuta: apt-get install whois   y reintenta.${NC}"
                unset PASS1 PASS2
                exit 1
            }
        fi

        ROOT_PASS_HASH=$(mkpasswd --method=sha-512 --stdin <<< "$PASS1")
        unset PASS1 PASS2
        if [[ "$ROOT_PASS_HASH" != \$6\$* ]]; then
            echo -e "${RED}❌ mkpasswd falló generando hash SHA-512.${NC}"; exit 1
        fi
        echo -e "${GREEN}✅ Contraseña encriptada exitosamente (SHA-512).${NC}"
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
                echo -e "  ${GREEN}✅ Clave válida agregada (${#SSH_KEYS[@]}).${NC}"
            else
                echo -e "  ${RED}❌ No parece una clave pública SSH válida — ignorada. Pega otra o Enter para terminar.${NC}"
            fi
        done
        if [[ "$AUTH_MODE" == "2" && ${#SSH_KEYS[@]} -eq 0 ]]; then
            echo -e "${RED}❌ Modo 'solo clave SSH' requiere al menos una clave. Abortando.${NC}"
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
    echo -e "\n${BLUE}🌐 Configuración de Red${NC}"

    # Solo bridges de Proxmox (vmbrN): excluye docker0, fwbr*, y los
    # sub-bridges vmbrXvY que crea el tagging VLAN en bridges legacy.
    mapfile -t BRIDGES < <(ip -br link show type bridge 2>/dev/null | awk '$1 ~ /^vmbr[0-9]+$/ && $2!="DOWN" {print $1}')
    [ ${#BRIDGES[@]} -eq 0 ] && { echo -e "${RED}❌ No hay bridges principales activos (ej. vmbr0)${NC}"; exit 1; }

    if [ ${#BRIDGES[@]} -eq 1 ]; then
        BRIDGE="${BRIDGES[0]}"
        echo -e "  ✅ Bridge único detectado y seleccionado: ${CYAN}${BRIDGE}${NC}"
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
                echo -e "${RED}❌ Índice inválido. Por favor selecciona un número del 1 al ${#BRIDGES[@]}.${NC}"
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
        echo -e "${RED}❌ VLAN inválida (debe ser entre 1 y 4094)${NC}"
    done

    while true; do
        read -p "IPv4 (ej. 192.168.1.100): " IPV4_VAL
        if valid_ipv4 "$IPV4_VAL"; then break; else echo -e "${RED}❌ IPv4 inválida${NC}"; fi
    done

    while true; do
        read -p "CIDR [24]: " IPV4_CIDR; IPV4_CIDR=${IPV4_CIDR:-24}
        if valid_cidr "$IPV4_CIDR"; then break; else echo -e "${RED}❌ CIDR inválido${NC}"; fi
    done

    while true; do
        read -p "Gateway IPv4: " GW_IPV4
        if valid_ipv4 "$GW_IPV4"; then break; else echo -e "${RED}❌ Gateway IPv4 inválido${NC}"; fi
    done

    echo -e "\n${BLUE}🌍 IPv6 (Opcional - Enter para omitir)${NC}"
    while true; do
        read -p "IPv6/prefijo (ej. 2803:c310:ff10::a/64): " IPV6_VAL
        [[ -z "$IPV6_VAL" ]] && break
        valid_ipv6_cidr "$IPV6_VAL" && break
        echo -e "${RED}❌ IPv6/prefijo inválido (formato esperado dirección/prefijo, ej. 2803:c310:ff10::a/64)${NC}"
    done
    if [[ -n "$IPV6_VAL" ]]; then
        while true; do
            read -p "Gateway IPv6: " GW_IPV6
            valid_ipv6_addr "$GW_IPV6" && break
            echo -e "${RED}❌ Gateway IPv6 inválido${NC}"
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
                echo -e "${RED}❌ '$ns' no es una IP válida (separa varios DNS con espacios)${NC}"
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
        echo -e "  ${YELLOW}⚠️  MAC ${VM_MAC} ya usada por otra VM/CT — regenerando...${NC}"
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

    read -p "✅ ¿Desplegar VM ahora? (s/N): " CONFIRM

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
    echo -e "\n${BLUE}📝 Generando archivo de configuración Cloud-Init (${OS_TYPE})...${NC}"

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
            echo -e "  ${GREEN}✅ YAML generado y validado correctamente por Python.${NC}"
        else
            echo -e "${RED}❌ El YAML generado tiene errores de sintaxis.${NC}"; exit 1
        fi
    fi
}
# FASE 8b: GENERACIÓN NETWORK-CONFIG v2 (Fix /32 on-link)
# ==============================================================================
generate_network_yaml() {
    echo -e "\n${BLUE}📝 Generando network-config v2 para Cloud-Init...${NC}"

    ( umask 077 && : > "$NETWORK_YAML_FILE" )

    # Determinar si necesitamos on-link (gateway en otra subred, típico con /32)
    local ONLINK_FLAG=""
    if [ "$IPV4_CIDR" -eq 32 ]; then
        ONLINK_FLAG="        on-link: true"
        echo -e "  ${YELLOW}⚠️  Detectada máscara /32: activando on-link para gateway${NC}"
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

    echo -e "  ${GREEN}✅ Network-config v2 generado correctamente.${NC}"
}

# FASE 9: DESPLIEGUE CON SISTEMA DE LOGS
# ==============================================================================
deploy_vm() {
    echo -e "\n${YELLOW}🏗️  Desplegando VM ${VMID} en Proxmox...${NC}"
    echo -e "${CYAN}📄 Guardando log de ejecución en: ${LOG_FILE}${NC}"

    echo "==========================================================" > "$LOG_FILE"
    echo "  LOG DE DESPLIEGUE PROXMOX - VM $VMID - $(date)" >> "$LOG_FILE"
    echo "==========================================================" >> "$LOG_FILE"

    IPCONFIG="ip=${IPV4_VAL}/${IPV4_CIDR},gw=${GW_IPV4}"
    [ "$IPV6_CONFIGURED" = true ] && IPCONFIG="${IPCONFIG},ip6=${IPV6_VAL},gw6=${GW_IPV6}"

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
📅 Desplegado: $(date '+%Y-%m-%d %H:%M')  ·  deploy-vm.sh v8.1
📝 Log: ${LOG_FILE}"

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
          --ide2 "${STORAGE_SNIP}:cloudinit" \
          --boot "order=scsi0" \
          --cpu "${CPU_TYPE}" \
          --ostype l26 \
          --agent enabled=1 \
          --onboot 1 \
          --serial0 socket \
          --vga serial0 \
          --description "$VM_DESCRIPTION" \
          --cicustom "user=${STORAGE_SNIP}:snippets/user-data-${VMID}.yaml,network=${STORAGE_SNIP}:snippets/network-data-${VMID}.yaml"

        echo -e "\n[2/3] Redimensionando el disco duro..."
        qm resize "$VMID" scsi0 "${DISK}G"
        
        echo -e "\n[3/3] Iniciando la Máquina Virtual..."
        qm start "$VMID"
    } >> "$LOG_FILE" 2>&1

    echo -e "\n${BLUE}⏳ Esperando a que el Guest Agent responda (cloud-init terminó)...${NC}"
    # 600s: con package_upgrade=true y un mirror lento, 300s daba falsos
    # "revisa cloud-init manualmente" en VMs que terminaban bien.
    local WAIT_MAX=600 WAITED=0
    while (( WAITED < WAIT_MAX )); do
        if qm guest cmd "$VMID" ping &>/dev/null; then
            echo -e "${GREEN}✅ Guest Agent activo tras ${WAITED}s.${NC}"
            break
        fi
        sleep 5
        WAITED=$((WAITED+5))
        printf "."
    done
    if (( WAITED >= WAIT_MAX )); then
        echo -e "\n${YELLOW}⚠️  Guest Agent no respondió en ${WAIT_MAX}s. La VM arrancó pero revisa cloud-init manualmente.${NC}"
    fi

    SUCCESS=true

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ ✅ VM ${VMID} creada y arrancada exitosamente       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Terminal : qm terminal ${VMID}"
    echo -e "${CYAN}Acceso   : ssh root@${IPV4_VAL}"
    echo -e "${CYAN}Log      : ${LOG_FILE}${NC}\n"
}

# ==============================================================================
# EJECUCIÓN PRINCIPAL
# ==============================================================================
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
