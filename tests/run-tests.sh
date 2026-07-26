#!/bin/bash
# ==============================================================================
# Banco de pruebas de deploy-vm.sh V8.1 — corre en un host Debian SIN Proxmox.
# Los comandos PVE (qm/pvesh/pvesm) y qemu-img/ip se stubean: nada real se
# crea; los stubs registran sus argumentos para las aserciones. wget/mkpasswd/
# ssh-keygen/findmnt/lsblk/python3 son REALES (descargas y checksums genuinos).
# ==============================================================================
D=/root/deploy-test
mkdir -p "$D/bin"
PASS=0; FAIL=0

ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check()    { grep -q -- "$2" "$3" 2>/dev/null && ok "$1" || bad "$1  [falta '$2' en $(basename "$3")]"; }
checknot() { grep -q -- "$2" "$3" 2>/dev/null && bad "$1  [presente '$2' en $(basename "$3")]" || ok "$1"; }

# ==================== STUBS ====================
cat > "$D/bin/qm" <<'EOF'
#!/bin/bash
D=/root/deploy-test
echo "qm $*" >> "$D/qm.log"
case "$1" in
  create)  touch "$D/vm-$2.exists"; exit 0 ;;
  status)  [ -f "$D/vm-$2.exists" ] && exit 0 || exit 2 ;;
  destroy) rm -f "$D/vm-$2.exists"; exit 0 ;;
  resize)  [ "${QM_FAIL_RESIZE:-0}" = "1" ] && { echo "resize fallo simulado" >&2; exit 1; }; exit 0 ;;
  guest)   exit 0 ;;
  *)       exit 0 ;;
esac
EOF

cat > "$D/bin/pvesh" <<'EOF'
#!/bin/bash
echo "pvesh $*" >> /root/deploy-test/pvesh.log
case "$*" in
  *"/cluster/nextid"*)    echo 999 ;;
  *"/cluster/resources"*) echo '[{"vmid":109,"type":"qemu","node":"otro-nodo"}]' ;;
  *"/storage/local"*)     echo '{"path":"/var/lib/vz","content":"iso,vztmpl,backup,import"}' ;;
  *)                      echo '{}' ;;
esac
EOF

cat > "$D/bin/pvesm" <<'EOF'
#!/bin/bash
echo "pvesm $*" >> /root/deploy-test/pvesm.log
case "$1" in
  status)
    echo "Name             Type     Status           Total            Used       Available        %"
    echo "local             dir     active       104857600        10485760        94371840   10.00%"
    ;;
  set) exit 0 ;;
esac
EOF

# ip: solo intercepta el listado de bridges; el resto pasa al ip real
cat > "$D/bin/ip" <<'EOF'
#!/bin/bash
if [ "$*" = "-br link show type bridge" ]; then
  echo "vmbr0            UP             aa:bb:cc:dd:ee:ff <BRIDGE,UP>"
  echo "docker0          UP             aa:bb:cc:dd:ee:00 <BRIDGE,UP>"
  echo "vmbr0v800        UP             aa:bb:cc:dd:ee:02 <BRIDGE,UP>"
  echo "fwbr109i0        UP             aa:bb:cc:dd:ee:01 <BRIDGE,UP>"
  exit 0
fi
for p in /usr/sbin/ip /sbin/ip /bin/ip /usr/bin/ip; do [ -x "$p" ] && exec "$p" "$@"; done
exit 1
EOF

# qemu-img: parsea el header qcow2 REAL de la imagen descargada (virtual-size
# está en el offset 24, 8 bytes big-endian) — medición genuina, sin qemu-utils
cat > "$D/bin/qemu-img" <<'EOF'
#!/bin/bash
f="${@: -1}"
python3 - "$f" <<'PYEOF'
import struct, sys, json
with open(sys.argv[1], 'rb') as fh:
    hdr = fh.read(32)
if hdr[:4] != b'QFI\xfb':
    sys.exit(1)
size = struct.unpack('>Q', hdr[24:32])[0]
print(json.dumps({"virtual-size": size, "format": "qcow2"}))
PYEOF
EOF

chmod +x "$D/bin/"*
export PATH="$D/bin:$PATH"

# Clave SSH real para las pruebas
[ -f "$D/tkey" ] || ssh-keygen -t ed25519 -f "$D/tkey" -N "" -q
KEY=$(cat "$D/tkey.pub")
SNIP=/var/lib/vz/snippets

reset_state() { rm -f "$D"/vm-*.exists "$D"/qm.log "$D"/pvesh.log "$D"/pvesm.log "$SNIP"/user-data-999.yaml "$SNIP"/network-data-999.yaml 2>/dev/null; touch "$D/qm.log" "$D/pvesm.log"; }

# ==============================================================================
echo "════════ RUN A: Debian 13 · auth 3 · IPv6 · VLAN · inputs inválidos ════════"
reset_state
printf '%s\n' \
  "2" \
  "109" \
  "" \
  "vm-prueba" \
  "9" \
  "3" \
  "ClaveTest123!" \
  "ClaveTest123!" \
  "esto-no-es-una-clave-ssh" \
  "$KEY" \
  "" \
  "5000" \
  "800" \
  "192.0.2.10" \
  "24" \
  "192.0.2.1" \
  "2001:db8::a/64" \
  "2001:db8::1" \
  "8.8.8.8 banana" \
  "" \
  "" \
  "2" \
  "20" \
  "si" \
  | bash "$D/deploy-vm.sh" > "$D/runA.out" 2>&1
RC_A=$?

[ $RC_A -eq 0 ] && ok "RUN A terminó con exit 0" || bad "RUN A exit=$RC_A (ver runA.out)"
check "Checksum Debian verificado (sha512)"          "Checksum OK (sha512sum)"                     "$D/runA.out"
check "Disco mínimo detectado desde la imagen"       "Disco virtual de la imagen:"                 "$D/runA.out"
check "VMID 109 rechazado (existe en cluster)"       "ya existe en el cluster"                     "$D/runA.out"
check "AUTH_MODE inválido re-pregunta"               "Debe ser 1, 2 o 3"                           "$D/runA.out"
check "Clave SSH inválida rechazada"                 "No parece una clave pública SSH válida"      "$D/runA.out"
check "Clave SSH válida aceptada"                    "Clave válida agregada"                       "$D/runA.out"
check "VLAN 5000 rechazada y re-pregunta"            "VLAN inválida"                               "$D/runA.out"
check "DNS 'banana' rechazado"                       "'banana' no es una IP válida"                "$D/runA.out"
check "Solo vmbr0 listado (docker0/fwbr/vmbrXvY fuera)" "Bridge único detectado"                   "$D/runA.out"
check "Guest agent OK (fin del deploy)"              "Guest Agent activo"                          "$D/runA.out"
check "YAML validado por PyYAML en el script"        "validado correctamente"                      "$D/runA.out"
check "pvesm set PRESERVA content + snippets"        "content iso,vztmpl,backup,import,snippets"   "$D/pvesm.log"
check "qm create con MAC OUI Proxmox"                "virtio=bc:24:11"                             "$D/qm.log"
check "qm create con tag=800"                        "tag=800"                                     "$D/qm.log"
check "qm create con queues=2 (2 cores)"             "queues=2"                                    "$D/qm.log"
check "qm create con cpu host (standalone)"          "--cpu host"                                  "$D/qm.log"
U="$SNIP/user-data-999.yaml"; N="$SNIP/network-data-999.yaml"
python3 -c "import yaml; yaml.safe_load(open('$U'))" 2>/dev/null && ok "user-data parsea (PyYAML)" || bad "user-data NO parsea"
python3 -c "import yaml; yaml.safe_load(open('$N'))" 2>/dev/null && ok "network-config parsea (PyYAML)" || bad "network-config NO parsea"
check "user-data: hash SHA-512 real de mkpasswd"     'password: .\$6\$'                            "$U"
check "user-data: clave SSH presente"                "ssh-ed25519"                                 "$U"
check "user-data: bootcmd una sola vez por instancia" "cloud-init-per instance deploy-dns"         "$U"
check "user-data: sysctl IPv6 estático"              "99-ipv6-static.conf"                         "$U"
check "user-data: PermitRootLogin yes (modo 3)"      "PermitRootLogin yes"                         "$U"
checknot "user-data Debian sin override netplan"     "99-cloud-init-override"                      "$U"
check "network-config: match por MAC"                "macaddress: \"bc:24:11"                      "$N"
check "network-config: IPv6 presente"                "2001:db8::a/64"                              "$N"
check "network-config: ruta ::/0 vía gw6"            "via: 2001:db8::1"                            "$N"
check "network-config: accept-ra false"              "accept-ra: false"                            "$N"
[ "$(stat -c %a "$U")" = "600" ] && ok "user-data con permisos 600" || bad "user-data permisos $(stat -c %a "$U")"
cp "$U" "$D/runA-user.yaml"; cp "$N" "$D/runA-net.yaml"

# ==============================================================================
echo "════════ RUN B: Ubuntu 24.04 · auth 2 (solo clave) · /32 on-link ════════"
reset_state
printf '%s\n' \
  "5" \
  "" \
  "vm-ubuntu" \
  "2" \
  "$KEY" \
  "" \
  "" \
  "198.51.100.7" \
  "32" \
  "10.0.0.1" \
  "" \
  "" \
  "" \
  "1" \
  "3" \
  "20" \
  "s" \
  | bash "$D/deploy-vm.sh" > "$D/runB.out" 2>&1
RC_B=$?

[ $RC_B -eq 0 ] && ok "RUN B terminó con exit 0" || bad "RUN B exit=$RC_B (ver runB.out)"
check "Checksum Ubuntu AHORA SÍ verificado (fix nombre remoto)" "Checksum OK (sha256sum)"          "$D/runB.out"
checknot "Ya no salta la verificación por nombre"    "Saltando verificación"                       "$D/runB.out"
check "Disco mínimo Noble = 4 GB (3.5 GiB virtual)"  "Disco virtual de la imagen: 4 GB"            "$D/runB.out"
check "Disco 3GB < imagen rechazado"                 "Disco mínimo 4GB"                            "$D/runB.out"
check "Aviso /32 on-link"                            "Detectada máscara /32"                       "$D/runB.out"
U="$SNIP/user-data-999.yaml"; N="$SNIP/network-data-999.yaml"
python3 -c "import yaml; yaml.safe_load(open('$U'))" 2>/dev/null && ok "user-data parsea (PyYAML)" || bad "user-data NO parsea"
python3 -c "import yaml; yaml.safe_load(open('$N'))" 2>/dev/null && ok "network-config parsea (PyYAML)" || bad "network-config NO parsea"
check "user-data: override netplan por MAC (Ubuntu)" "macaddress: \"bc:24:11"                      "$U"
check "user-data: chmod 600 del override netplan"    "chmod 600 /etc/netplan/99-cloud-init-override.yaml" "$U"
check "user-data: PermitRootLogin prohibit-password (modo 2)" "PermitRootLogin prohibit-password"  "$U"
check "user-data: PasswordAuthentication no (modo 2)" "PasswordAuthentication no"                  "$U"
checknot "user-data: SIN hash de password (modo 2)"  'password: .\$6\$'                            "$U"
check "network-config: on-link para /32"             "on-link: true"                               "$N"
check "qm create con ip .../32"                      "ip=198.51.100.7/32"                          "$D/qm.log"
checknot "qm create SIN multiqueue (1 core)"         "queues="                                     "$D/qm.log"
cp "$U" "$D/runB-user.yaml"; cp "$N" "$D/runB-net.yaml"

# ==============================================================================
echo "════════ RUN C: rollback E2E — qm resize FALLA dentro de deploy_vm() ════════"
reset_state
export QM_FAIL_RESIZE=1
printf '%s\n' \
  "2" \
  "" \
  "vm-fail" \
  "1" \
  "PassFallo1!" \
  "PassFallo1!" \
  "" \
  "192.0.2.20" \
  "24" \
  "192.0.2.1" \
  "" \
  "" \
  "" \
  "1" \
  "20" \
  "s" \
  | bash "$D/deploy-vm.sh" > "$D/runC.out" 2>&1
RC_C=$?
unset QM_FAIL_RESIZE

[ $RC_C -ne 0 ] && ok "RUN C salió con error (exit=$RC_C)" || bad "RUN C debió fallar y salió 0"
# El mensaje del rollback puede salir por stdout o quedar en el log del deploy
# (el trap dispara dentro del bloque redirigido) — buscar en ambos
cat "$D/runC.out" /var/log/proxmox-deploy/deploy_VM999_*.log > "$D/runC.all" 2>/dev/null
check "Imagen tomada de caché (2ª vez)"              "encontrada en caché local"                   "$D/runC.out"
check "Rollback SE EJECUTÓ (fix set -E: antes moría en silencio)" "Limpiando recursos parciales"   "$D/runC.all"
check "Rollback destruyó la VM parcial"              "qm destroy 999"                              "$D/qm.log"
[ ! -f "$D/vm-999.exists" ] && ok "VM parcial eliminada" || bad "VM parcial sigue existiendo"
[ ! -f "$SNIP/user-data-999.yaml" ] && ok "Snippet user-data limpiado" || bad "Snippet user-data quedó huérfano"
[ ! -f "$SNIP/network-data-999.yaml" ] && ok "Snippet network limpiado" || bad "Snippet network quedó huérfano"

# ==============================================================================
echo "════════ RUN D: abort temprano — opción de SO inválida ════════"
echo "7" | bash "$D/deploy-vm.sh" > "$D/runD.out" 2>&1
RC_D=$?
[ $RC_D -ne 0 ] && ok "RUN D salió con error (exit=$RC_D)" || bad "RUN D debió fallar y salió 0"
check "Mensaje de abort sin cambios en el nodo"      "No se hicieron cambios en el nodo"           "$D/runD.out"

# ==============================================================================
echo ""
echo "══════════════════════ RESULTADO ══════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL"
[ $FAIL -eq 0 ] && echo "  🟢 TODAS LAS PRUEBAS PASARON" || echo "  🔴 HAY FALLOS — revisar $D/run*.out"
exit $(( FAIL > 0 ? 1 : 0 ))
