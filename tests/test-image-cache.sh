#!/bin/bash
# ==============================================================================
# Pruebas de la caché de imágenes de deploy-vm.sh (v8.2).
#
# NO necesita red, ni Proxmox, ni descargar 350 MB: monta un "upstream" falso en
# un directorio temporal y stubea wget, de modo que se pueden forzar a voluntad
# los casos que en la vida real tardan semanas en aparecer — que Debian/Ubuntu
# republiquen 'latest'/'current', que la caché se corrompa o que el mirror caiga.
#
# Complementa a run-tests.sh (que sí hace descargas reales y prueba el deploy
# completo). Este corre en segundos y en cualquier máquina con bash.
#
#   bash tests/test-image-cache.sh ./deploy-vm.sh
# ==============================================================================
set -uo pipefail

SRC="${1:-./deploy-vm.sh}"
[ -f "$SRC" ] || { echo "No encuentro deploy-vm.sh (pásalo como argumento)"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1  [esperado '$3', obtenido '$2']"; }
has()    { grep -q -- "$2" "$T/out" && ok "$1" || bad "$1  [falta '$2']"; }
hasnot() { grep -q -- "$2" "$T/out" && bad "$1  [presente '$2']" || ok "$1"; }

UP="$T/upstream"; CACHE="$T/cache"; mkdir -p "$UP" "$CACHE"
IMG=debian-13-genericcloud-amd64.qcow2
B=debian-13-genericcloud-amd64; E=qcow2

GREEN=''; YELLOW=''; RED=''; BLUE=''; CYAN=''; NC=''

# ==============================================================================
echo "═══════════ PARTE 1: funciones de caché aisladas ═══════════"
# ==============================================================================
sed -n '/==== CACHÉ DE IMÁGENES/,/==== FUNCIONES DE DETECCIÓN/p' "$SRC" > "$T/funcs.sh"
grep -q 'prune_old_builds()' "$T/funcs.sh" || { echo "no se extrajeron las funciones"; exit 1; }
# shellcheck disable=SC1090
source "$T/funcs.sh"

eq "cache_builds sin archivos devuelve vacío (no el literal del glob)" \
   "$(cache_builds "$CACHE" "$B" "$E")" ""

touch -d '2026-08-01' "$CACHE/${B}-aaaaaaaaaaaa.${E}"
touch -d '2026-08-10' "$CACHE/${B}-bbbbbbbbbbbb.${E}"
touch -d '2026-08-05' "$CACHE/${B}-cccccccccccc.${E}"
touch "$CACHE/ubuntu-24.04-server-cloudimg-amd64-dddddddddddd.img"   # otra familia
touch "$CACHE/${B}.${E}"                                            # nombre legacy

eq "cache_builds ordena por mtime, la más reciente primero" \
   "$(cache_builds "$CACHE" "$B" "$E" | xargs -n1 basename | tr '\n' ' ')" \
   "${B}-bbbbbbbbbbbb.${E} ${B}-cccccccccccc.${E} ${B}-aaaaaaaaaaaa.${E} "
eq "cache_builds no mezcla otras familias de imagen" \
   "$(cache_builds "$CACHE" "$B" "$E" | grep -c ubuntu || true)" "0"
eq "cache_builds ignora el archivo legacy sin sufijo" \
   "$(cache_builds "$CACHE" "$B" "$E" | grep -cx ".*/${B}\.${E}" || true)" "0"

SUM=0ce1f1d675733027d3e17a4665cb95e1d7173bdf67fb8a87ff822ff5ee025bc2a
eq "el nombre de caché es base-<12 primeros del hash>.ext" \
   "${B}-${SUM:0:12}.${E}" "${B}-0ce1f1d67573.qcow2"

KEEP="$CACHE/${B}-bbbbbbbbbbbb.${E}"
OUT=$(prune_old_builds "$CACHE" "$B" "$E" "$KEEP" </dev/null); rc=$?
eq "prune_old_builds devuelve 0 (no rompe set -e)" "$rc" "0"
eq "prune_old_builds cuenta las 2 builds viejas" \
   "$(echo "$OUT" | grep -c 'aaaaaaaaaaaa\|cccccccccccc')" "2"
eq "prune_old_builds no lista la build en uso" \
   "$(echo "$OUT" | grep -c bbbbbbbbbbbb || true)" "0"
[ -f "$CACHE/${B}-aaaaaaaaaaaa.${E}" ] && ok "sin TTY no borra nada" || bad "borró sin preguntar"

rm -f "$CACHE/${B}-"*".${E}" "$CACHE/${B}.${E}" "$CACHE/ubuntu"*
OUT2=$(prune_old_builds "$CACHE" "$B" "$E" "$KEEP" </dev/null); rc2=$?
eq "prune_old_builds con array vacío devuelve 0 (set -u)" "$rc2" "0"
eq "prune_old_builds no imprime nada si no hay viejas" "$OUT2" ""

# ==============================================================================
echo "═══════════ PARTE 2: select_os_and_download() end-to-end ═══════════"
# ==============================================================================
publish() {   # publica una build nueva en el upstream falso
    printf 'QFI\xfb%s' "$1" > "$UP/$IMG"
    head -c 4096 /dev/zero >> "$UP/$IMG"
    (cd "$UP" && sha512sum "$IMG" > SHA512SUMS)
}
upstream_sum() { awk '{print $1}' "$UP/SHA512SUMS"; }

mkdir -p "$T/bin"
cat > "$T/bin/wget" <<'EOF'
#!/bin/bash
UP="$UPSTREAM_DIR"
dest=""; url=""; spider=0; showhdr=0
while [ $# -gt 0 ]; do
  case "$1" in
    -O) dest="$2"; shift 2 ;;
    --spider) spider=1; shift ;;
    -qS|-S) showhdr=1; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "$url" = "https://8.8.8.8" ] && exit 0            # chequeo de conectividad
case "$url" in
  *SHA512SUMS) src="$UP/SHA512SUMS" ;;
  *.qcow2)     src="$UP/debian-13-genericcloud-amd64.qcow2" ;;
  *)           exit 1 ;;
esac
if [ "$spider" = 1 ]; then
  [ "$showhdr" = 1 ] && echo "  Content-Length: $(stat -c %s "$src")" >&2
  exit 0
fi
# la sonda de mirror escribe a /dev/null; solo la descarga real puede fallar
if [ "$dest" != "/dev/null" ] && [ "${FAIL_DOWNLOAD:-0}" = "1" ] && [[ "$url" == *.qcow2 ]]; then
  exit 1
fi
cp "$src" "${dest:-/dev/stdout}"
EOF
chmod +x "$T/bin/wget"
export UPSTREAM_DIR="$UP"
export PATH="$T/bin:$PATH"

# El script hasta el final de select_os_and_download, sin registrar el trap y
# con la ruta de caché apuntada al temporal.
sed -n '1,/FASE 2: AUTO-SELECCIÓN/p' "$SRC" \
  | grep -v '^trap rollback' \
  | sed "s#/var/lib/vz/template/iso#$CACHE#g" > "$T/lib.sh"

run() {   # run <respuestas que se teclearían tras elegir el SO>
    ( set +e
      # shellcheck disable=SC1090
      source "$T/lib.sh" 2>/dev/null
      # stdin desde archivo y NO por pipe: un pipe ejecutaría la función en una
      # subshell y FILE_PATH no sobreviviría para las aserciones
      printf '%s\n' "2" "$@" > "$T/in"
      select_os_and_download < "$T/in"
      echo "__FILE_PATH=$FILE_PATH"
    ) > "$T/out" 2>&1
    FP=$(sed -n 's/^__FILE_PATH=//p' "$T/out")
}
nbuilds() { ls -1 "$CACHE/$B-"*".$E" 2>/dev/null | wc -l; }

echo "── 1. Primera descarga ──"
publish AAAA; SUM1=$(upstream_sum)
run
has "descarga la imagen"                     "Descargando"
has "verifica el checksum"                   "Checksum OK"
eq  "la guarda con el hash de la build en el nombre" "$FP" "$CACHE/$B-${SUM1:0:12}.$E"

echo "── 2. Misma build: no debe volver a descargar ──"
run
hasnot "no descarga"                         "Descargando"
has    "reconoce la build en caché"          "ya está en caché"
eq     "sigue habiendo una sola build"       "$(nbuilds)" "1"

echo "── 3. Upstream republica · Enter (default) = usar caché ──"
publish BBBB; SUM2=$(upstream_sum)
run ""
has    "avisa de que hay una build más reciente" "build más reciente"
hasnot "no descarga"                         "Descargando"
has    "usa la build en caché"               "Usando la build en caché"
eq     "sigue apuntando a la build vieja"    "$FP" "$CACHE/$B-${SUM1:0:12}.$E"

echo "── 4. Igual pero respondiendo 'n' = bajar la nueva ──"
run "n"
has "descarga la nueva"                      "Descargando"
has "checksum de la nueva OK"                "Checksum OK"
eq  "apunta a la build nueva"                "$FP" "$CACHE/$B-${SUM2:0:12}.$E"
eq  "conserva ambas builds en caché"         "$(nbuilds)" "2"

echo "── 5. IMAGE_REFRESH=never (no interactivo) ──"
publish CCCC; SUM3=$(upstream_sum)
IMAGE_REFRESH=never run
hasnot "no descarga"                         "Descargando"
has    "usa la caché sin preguntar"          "Usando la build en caché"

echo "── 6. IMAGE_REFRESH=always (no interactivo) ──"
IMAGE_REFRESH=always run
has "descarga sin preguntar"                 "Descargando"
eq  "apunta a la build nueva"                "$FP" "$CACHE/$B-${SUM3:0:12}.$E"

echo "── 7. Migración del esquema viejo (archivo sin sufijo de build) ──"
rm -f "$CACHE/$B-"*".$E"
cp "$UP/$IMG" "$CACHE/$IMG"                 # como lo dejaban las versiones <= 8.1
run
has    "reetiqueta la imagen heredada"       "Reetiquetando la imagen heredada"
hasnot "no la re-descarga"                   "Descargando"
has    "la reconoce como la build actual"    "ya está en caché"
[ ! -f "$CACHE/$IMG" ] && ok "no deja el archivo viejo duplicado" || bad "quedó duplicado"

echo "── 8. Caché corrupta (mismo nombre, contenido alterado) ──"
printf 'basura' >> "$CACHE/$B-${SUM3:0:12}.$E"
run
has "detecta la corrupción"                  "corrupta"
has "la vuelve a descargar"                  "Descargando"
has "y queda verificada"                     "Checksum OK"

echo "── 9. Mirror caído con build previa en caché ──"
publish DDDD
FAIL_DOWNLOAD=1 run "n"
has "avisa del fallo de descarga"            "Falló la descarga"
has "continúa con la build anterior"         "se continúa con la build anterior"
{ [ -n "$FP" ] && [ -f "$FP" ]; } && ok "FILE_PATH apunta a un archivo existente" || bad "FP='$FP'"

echo "── 10. Sin archivo de sumas → reutiliza la caché sin verificar ──"
mv "$UP/SHA512SUMS" "$UP/SHA512SUMS.off"
run
has    "avisa de que no hay verificación"    "sin verificación de integridad"
hasnot "no descarga a ciegas"                "Descargando"
mv "$UP/SHA512SUMS.off" "$UP/SHA512SUMS"

echo
echo "══════════════════════ RESULTADO ══════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL"
[ $FAIL -eq 0 ] && echo "  🟢 TODAS LAS PRUEBAS PASARON" || echo "  🔴 HAY FALLOS"
exit $(( FAIL > 0 ? 1 : 0 ))
