#!/bin/bash
# Comprueba los validadores de IP y la logica de net_snippet_needed / cicustom.
#
# OJO con extraer funciones del script con rangos sed encadenados: valid_ipv4 y
# valid_cidr son de una sola linea y no cierran con '}' en columna 0, asi que un
# rango /^f()/,/^}/ se come las funciones siguientes y mezcla definiciones. Da
# falsos positivos (durante la auditoria "zzz::1/64" parecio valida por esto).
# Aqui se extrae cada funcion con un parser que respeta ese detalle.
set -Eeuo pipefail
SRC="${1:?ruta a deploy-vm.sh}"

extraer() {  # extraer <nombre>
    python3 - "$SRC" "$1" <<'PY'
import io,re,sys
lines=io.open(sys.argv[1],encoding='utf-8').read().split('\n')
name=sys.argv[2]
for i,l in enumerate(lines):
    if re.match(r'^%s\(\)\s*\{' % re.escape(name), l):
        # de una linea?
        if l.rstrip().endswith('}'):
            print(l); sys.exit(0)
        j=i+1
        while j<len(lines) and lines[j]!='}':
            j+=1
        print('\n'.join(lines[i:j+1])); sys.exit(0)
sys.exit("no se encontro %s" % name)
PY
}

for f in valid_ipv4 valid_cidr valid_ipv6_addr valid_ipv6_cidr net_snippet_needed; do
    eval "$(extraer "$f")"
done

FALLOS=0
chk() {  # chk <descripcion> <esperado ok|ko> <comando...>
    local desc="$1" esp="$2"; shift 2
    if "$@" >/dev/null 2>&1; then real=ok; else real=ko; fi
    if [ "$real" = "$esp" ]; then
        printf '  [OK]  %s\n' "$desc"
    else
        printf '  [FALLO] %s (esperaba %s, dio %s)\n' "$desc" "$esp" "$real"
        FALLOS=$((FALLOS+1))
    fi
}

echo "=== IPv4 ==="
chk 'valid_ipv4 10.0.0.5'        ok valid_ipv4 "10.0.0.5"
chk 'valid_ipv4 255.255.255.255' ok valid_ipv4 "255.255.255.255"
chk 'valid_ipv4 999.1.1.1'       ko valid_ipv4 "999.1.1.1"
chk 'valid_ipv4 1.2.3'           ko valid_ipv4 "1.2.3"
chk 'valid_ipv4 vacia'           ko valid_ipv4 ""
chk 'valid_ipv4 texto'           ko valid_ipv4 "hola"

echo "=== no contamina globales (hallazgo B1) ==="
a=CENTINELA; valid_ipv4 "10.0.0.5" || true
[ "$a" = "CENTINELA" ] && echo "  [OK]  \$a intacta" || { echo "  [FALLO] \$a pisada: $a"; FALLOS=$((FALLOS+1)); }

echo "=== prefijo IPv4 ==="
chk 'valid_cidr 24'  ok valid_cidr 24
chk 'valid_cidr 32'  ok valid_cidr 32
chk 'valid_cidr 33'  ko valid_cidr 33
chk 'valid_cidr xx'  ko valid_cidr xx

echo "=== IPv6 (hallazgo A1 se apoya en esto) ==="
chk 'valid_ipv6_cidr 2001:db8::10/64' ok valid_ipv6_cidr "2001:db8::10/64"
chk 'valid_ipv6_cidr ::1/128'         ok valid_ipv6_cidr "::1/128"
chk 'valid_ipv6_cidr sin prefijo'     ko valid_ipv6_cidr "2001:db8::10"
chk 'valid_ipv6_cidr zzz::1/64'       ko valid_ipv6_cidr "zzz::1/64"
chk 'valid_ipv6_cidr prefijo 999'     ko valid_ipv6_cidr "2001:db8::10/999"
chk 'valid_ipv6_addr 2001:db8::1'     ok valid_ipv6_addr "2001:db8::1"
chk 'valid_ipv6_addr 10.0.0.1'        ko valid_ipv6_addr "10.0.0.1"

echo "=== cuando hace falta snippet de red ==="
snip() { IPV4_CIDR="$1" IPV6_CONFIGURED="$2" net_snippet_needed; }
chk '/24 sin IPv6 -> nativo'  ko snip 24 false
chk '/30 sin IPv6 -> nativo'  ko snip 30 false
chk '/32 sin IPv6 -> snippet' ok snip 32 false
chk '/24 con IPv6 -> snippet' ok snip 24 true
chk '/32 con IPv6 -> snippet' ok snip 32 true

echo
if [ "$FALLOS" -eq 0 ]; then
    echo "[OK] Todas las comprobaciones pasaron."
else
    echo "[ERROR] ${FALLOS} comprobacion(es) fallaron."
    exit 1
fi
