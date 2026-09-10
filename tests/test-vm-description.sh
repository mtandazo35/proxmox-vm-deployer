#!/bin/bash
# Genera de VERDAD IP_CHANGE_NOTE + VM_DESCRIPTION en ambas ramas.
# Es la clase de fallo que rompio el despliegue en la v8.3 (backticks que se
# ejecutaban) y que 'bash -n' NO detecta: hay que construir la cadena.
set -Eeuo pipefail
SRC="${1:?ruta a deploy-vm.sh}"

GREEN=""; YELLOW=""; RED=""; BLUE=""; CYAN=""; NC=""
eval "$(sed -n '/^net_snippet_needed()/,/^}/p' "$SRC")"

BLOQUE=$(sed -n '/^    # OJO: nada de/,/^📝 Log: \${LOG_FILE}"$/p' "$SRC")

probar() {
    IPV4_CIDR="$1"; IPV6_CONFIGURED="$2"
    NOMBRE=web; VMID=777; OS_PRETTY="Debian 13"; IMAGE_NAME=img.qcow2
    RAM=2048; CPU=2; DISK=20; STORAGE_IMG=local-lvm; STORAGE_SSD_FLAG=""
    CPU_TYPE=host; BRIDGE=vmbr0; VLAN_TAG=",tag=87"; VM_MAC="bc:24:11:aa:bb:cc"
    DNS_SERVERS="8.8.8.8 1.1.1.1"; LOG_FILE=/tmp/x.log; STORAGE_SNIP=local
    IPV4_VAL=10.0.0.5; GW_IPV4=10.0.0.1
    IPV6_VAL="2001:db8::5/64"; GW_IPV6="2001:db8::1"
    AUTH_MODE=2; SSH_KEYS=("ssh-ed25519 AAAA")

    echo "################  /${IPV4_CIDR}   ipv6=${IPV6_CONFIGURED}  ################"

    # eval dentro de la funcion: los 'local' del bloque son validos aqui
    eval "$BLOQUE"

    local CIC="user=${STORAGE_SNIP}:snippets/user-data-${VMID}.yaml"
    net_snippet_needed && CIC="${CIC},network=${STORAGE_SNIP}:snippets/network-data-${VMID}.yaml"
    echo "cicustom : $CIC"
    echo "--- lo que veria el usuario en las notas de la VM ---"
    echo "$VM_DESCRIPTION" | sed -n '/Como cambiar la IP/,/^---$/p'
    echo
}

probar 24 false
probar 32 false
probar 24 true

echo "[OK] Las tres combinaciones generan la descripcion sin ejecutar nada."
