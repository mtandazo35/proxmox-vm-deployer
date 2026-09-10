# Auditoría — `deploy-vm.sh` v8.5

**Fecha:** 2026-09-10  ·  **Commit:** `5a7136d`  ·  **Líneas:** 1639

## Integridad de los archivos auditados

```
4b4150c448d04a3c88dd4e22d848ac0f6b863e444e7d64615a897ace2ca76363  deploy-vm.sh
cd01e2cdd35f892ce4a471959802b681074e1024aae503af56962f7126492733  README.md
94818a3b223421b1c52e5e6e17cff7acdff31903aef55a6386265b133b7f94c6  tests/run-tests.sh
e2b194afa71924fa7ce54fc70eef68e34337a47a2913da9c34b28e00c28fc71c  tests/test-image-cache.sh
5cfcdcf5e823fad3fd14bd5e384de07b624b49ecc0b960d14f2bfb4fc86f3905  tests/test-vm-description.sh
```

`shellcheck` no estaba disponible en el entorno de auditoría; el análisis es manual
más comprobaciones dinámicas ejecutadas contra un nodo Proxmox real
(**CAFANET**, PVE 9.2.11, Debian 13.6).

---

## Resumen

| Severidad | Nº | Hallazgos |
|---|---|---|
| Alta | 3 | A1, A2, A3 |
| Media | 4 | M1, M2, M3, M4 |
| Baja | 5 | B1–B5 |

Todos los hallazgos de severidad alta están en `change_vm_ip()` (modo
`--cambiar-ip`, introducido en v8.3). El flujo de despliegue original está en
mucho mejor estado: sus validaciones son completas y sus puntos delicados
—rollback, checksum, MAC, cachés— ya estaban cubiertos por auditorías previas.

---

## Comprobaciones que PASAN (no son hallazgos)

Se verificaron y quedaron limpias:

1. **Ninguna función termina en una lista `&&` que pueda devolver 1.** Se
   analizaron las 28 funciones del script. Importa porque `[ cond ] && algo`
   **como última sentencia de una función** hace que la función devuelva 1 y,
   bajo `set -e`, mata el script; a mitad de función es inofensivo. Verificado
   empíricamente:
   ```
   f() { echo entro; [ 0 = 1 ] && return 0; echo SIGO; }   -> sigue vivo
   g() { echo entro; [ 0 = 1 ] && return 0; }               -> MATA el script
   ```
   Los dos casos que el análisis señala (`valid_ipv6_addr`, `net_snippet_needed`)
   son predicados usados dentro de `if`, donde `set -e` no aplica.

2. **`tar` restaura sobre `/etc/pve` (pmxcfs).** Es la premisa del rollback de
   `--cambiar-ip` y no era obvia, al ser un FUSE. Probado en CAFANET: extrae sin
   error y el md5 del `.conf` coincide.

3. **El rollback de `--cambiar-ip` no destruye la VM.** Probado con VMID
   inexistente, vacío y no numérico: las VMs del nodo intactas en los tres casos.
   El `trap` del despliegue (que sí hace `qm destroy --purge`) se desarma como
   primera instrucción de la función.

4. **La autoactualización valida antes de instalar.** Probado de extremo a
   extremo: detecta diferencia, descarga, comprueba `#!/bin/bash` y `bash -n`,
   reemplaza, guarda `.anterior` y se reejecuta. El SHA256 resultante coincide
   con el del repo.

5. **Autenticación.** `AUTH_MODE` validado (un typo dejaba VMs inaccesibles),
   `mkpasswd` comprobado e instalado si falta, `PASS1`/`PASS2` con `unset` tras
   hashear, hash verificado (`$6$`), cada clave SSH validada con `ssh-keygen`, y
   el modo "solo clave" aborta si no hay ninguna.

---

## Hallazgos de severidad ALTA

### A1 — `--cambiar-ip` no valida la IPv6 que se le teclea

**Dónde:** `change_vm_ip()`, bloque «IPv6 opcional».

El script tiene validadores (`valid_ipv6_cidr`, `valid_ipv6_addr`) y el flujo de
despliegue **sí** los usa (líneas 890 y 896). El modo `--cambiar-ip` los ignora:

```bash
read -p "IPv6 (Enter para omitir, ej. 2001:db8::10/64): " NEW_IP6
if [ -n "$NEW_IP6" ]; then
    IPV6_VAL="$NEW_IP6"; IPV6_CONFIGURED=true
    read -p "Gateway IPv6 (Enter para omitir): " GW_IPV6
fi
```

**Impacto:** un typo entra tal cual al snippet de netplan. Netplan rechaza el
fichero entero y la VM arranca **sin red** — y como el cambio implica apagar y
encender, el usuario se queda sin acceso a una VM que antes funcionaba.
Agravante: introducir cualquier IPv6 activa `net_snippet_needed`, así que el
valor inválido sí acaba en el snippet.

**Parche:**

```bash
    IPV6_CONFIGURED=false; IPV6_VAL=""; GW_IPV6=""
    while true; do
        read -r -p "IPv6 (Enter para omitir, ej. 2001:db8::10/64): " NEW_IP6
        [ -z "$NEW_IP6" ] && break
        if valid_ipv6_cidr "$NEW_IP6"; then
            IPV6_VAL="$NEW_IP6"; IPV6_CONFIGURED=true
            while true; do
                read -r -p "Gateway IPv6 (Enter para omitir): " GW_IPV6
                [ -z "$GW_IPV6" ] && break
                valid_ipv6_addr "$GW_IPV6" && break
                echo -e "${RED}[ERROR] Gateway IPv6 invalido.${NC}"
            done
            break
        fi
        echo -e "${RED}[ERROR] IPv6 invalida. Formato: direccion/prefijo.${NC}"
    done
```

---

### A2 — Una VM sin `cicustom` que pase a necesitar snippet queda con el cambio sin aplicar, y en silencio

**Dónde:** `change_vm_ip()`, bloque «1) dejar la VM en el modo que exige la
configuración NUEVA».

```bash
local CIC_NEW="user=${userref}"
...
[ -n "$userref" ] && qm set "$id" --cicustom "$CIC_NEW" >/dev/null
```

Si la VM no tiene `cicustom` (creada a mano, o por otro medio), `userref` queda
vacío y el `qm set` **se salta**. Pero `generate_network_yaml` ya escribió el
snippet: queda un `network-data-<VMID>.yaml` en disco que **nadie referencia**.

**Impacto:** con un `/32` o IPv6 en una VM así, el usuario ve todos los mensajes
de éxito, la VM se reinicia, y la IP no cambia. Es exactamente el modo de fallo
silencioso que motivó todo este trabajo.

**Parche:**

```bash
    local CIC_NEW=""
    [ -n "$userref" ] && CIC_NEW="user=${userref}"
    if net_snippet_needed; then
        generate_network_yaml
        [ -n "$CIC_NEW" ] && CIC_NEW="${CIC_NEW},"
        CIC_NEW="${CIC_NEW}network=${snipstore}:snippets/network-data-${id}.yaml"
        ...
    fi
    if [ -n "$CIC_NEW" ]; then
        qm set "$id" --cicustom "$CIC_NEW" >/dev/null
    elif [ "$HAD_SNIPPET" = true ]; then
        qm set "$id" --delete cicustom >/dev/null    # se retiro el unico componente
    fi
```

---

### A3 — Si la VM no se apaga en 60 s, el fallo es confuso

**Dónde:** `change_vm_ip()`, paso 4.

```bash
qm stop "$id" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do qm status "$id" 2>/dev/null | grep -q stopped && break; sleep 2; done
```

Agotado el bucle **se continúa igualmente** a `qm start`, que falla con «already
running» → `set -e` → rollback. El usuario recibe «Fallo al cambiar la IP» sin
saber que la causa real fue que la VM no se apagó.

**Impacto:** medio en frecuencia, alto en confusión. Un guest que ignora ACPI
(pasa con imágenes sin `qemu-guest-agent` operativo) lo provoca siempre.

**Parche:**

```bash
        local parada=false
        for _ in $(seq 1 30); do
            qm status "$id" 2>/dev/null | grep -q stopped && { parada=true; break; }
            sleep 2
        done
        if [ "$parada" = false ]; then
            echo -e "${YELLOW}[AVISO] La VM no se apago en 60s; forzando...${NC}"
            qm stop "$id" --skiplock 1 >/dev/null 2>&1 || true
            sleep 5
            if ! qm status "$id" 2>/dev/null | grep -q stopped; then
                echo -e "${RED}[ERROR] No se pudo apagar la VM ${id}. No se ha cambiado nada mas.${NC}"
                exit 1
            fi
        fi
```

---

## Hallazgos de severidad MEDIA

### M1 — El DNS de la VM se puede sustituir silenciosamente por `8.8.8.8 1.1.1.1`

```bash
DNS_SERVERS=$(awk -F': ' '/^nameserver:/{print $2}' <<< "$conf" || true)
[ -z "$DNS_SERVERS" ] && DNS_SERVERS="8.8.8.8 1.1.1.1"
```

Si la VM no tiene `nameserver:` en la config de Proxmox porque su DNS vive solo
en el snippet, `--cambiar-ip` lo pisa con los públicos. En un servidor de un ISP
—que es el caso de uso— eso puede sacar al resolver de su propia jerarquía.

**Parche:** leer primero del snippet existente y solo entonces caer al defecto:

```bash
    if [ -z "$DNS_SERVERS" ] && [ -f "$NETWORK_YAML_FILE" ]; then
        DNS_SERVERS=$(awk '/nameservers:/{f=1;next} f&&/^ *- /{gsub(/[- ]/,"");printf "%s ",$0} f&&/^ *[a-z]+:/&&!/addresses:/{exit}' "$NETWORK_YAML_FILE")
    fi
    [ -z "$DNS_SERVERS" ] && DNS_SERVERS="8.8.8.8 1.1.1.1"
```

### M2 — IPv6 sin gateway no llega a `ipconfig0`

```bash
[ "$IPV6_CONFIGURED" = true ] && [ -n "$GW_IPV6" ] && IPCONFIG="${IPCONFIG},ip6=..."
```

Con IPv6 pero sin gateway, `ipconfig0` no recibe `ip6=`, así que el panel no
muestra la IPv6 aunque el snippet sí la tenga. Es el tipo de discrepancia
panel↔realidad que este proyecto lleva dos versiones intentando eliminar.

**Parche:** añadir `ip6=` siempre que haya IPv6, y `gw6=` solo si hay gateway.

### M3 — La confirmación de `--cambiar-ip` rechaza «si»

Línea 1546: `[[ "$OK" =~ ^[sS]$ ]]`. El resto del script usa
`^(s|si|sí|y|yes)$` (líneas 239, 514). Quien escriba «si» cancelará sin querer y
creerá que el script no funciona.

**Parche:** `[[ "${OK,,}" =~ ^(s|si|sí|y|yes)$ ]]`.

### M4 — 20 de 25 `read` sin `-r`

`read` sin `-r` interpreta `\` como escape. Afecta a rutas, claves SSH pegadas y
contraseñas con barra invertida: se manglan **en silencio**. Solo 5 lecturas
usan `-r`.

**Parche:** `sed -i 's/read -p /read -r -p /g; s/read -s -p /read -r -s -p /g' deploy-vm.sh`
(revisar después: no debe tocarse el `read` que ya lleva `-r`).

---

## Hallazgos de severidad BAJA

- **B1** — `valid_ipv4()` usa `IFS='.' read -r a b c d` sin `local`: contamina
  las globales `a`, `b`, `c`, `d`. Hoy no colisiona, pero es una mina.
- **B2** — El bucle de claves SSH (línea 804) usa `line` como global.
- **B3** — La autoactualización **ejecuta código remoto como root** confiando
  solo en TLS. Es una decisión legítima, pero conviene documentarla y considerar
  fijar un tag o comprobar un SHA256 publicado.
- **B4** — `mkpasswd --stdin <<< "$PASS1"`: un *herestring* de bash escribe en un
  fichero temporal, así que la contraseña en claro toca disco un instante.
  `printf '%s' "$PASS1" | mkpasswd --method=sha-512 --stdin` lo evita.
- **B5** — `deploy-vm.sh.anterior` se sobrescribe sin límite y no se limpia nunca.

---

## Nota sobre la familia de fallos recurrente

Tres fallos distintos de la misma raíz han llegado al código, y **ninguno lo
detecta `bash -n`**, porque los tres son sintaxis válida que solo revienta al
ejecutarse:

1. **Backticks sin escapar** dentro de `VM_DESCRIPTION` (cadena entre comillas
   dobles) → sustitución de comandos → `cicustom: command not found` y, con
   `set -e`, despliegue abortado. **Llegó a producción.**
2. **`$(...)` dentro de una asignación**: bajo `set -e` el estado de la
   asignación es el de su última sustitución, así que un `[ ... ]` en falso mata
   el script. Habría roto todos los despliegues `/32` e IPv6.
3. **Heredoc sin comillas** (`<<AYUDA` en vez de `<<'AYUDA'`) para expandir una
   variable: expande también los backticks del texto.

`tests/test-vm-description.sh` existe por esto y cazó el nº 2. **Recomendación:**
ampliarlo para que cubra cada cadena larga del script, no solo la descripción de
la VM, y añadir `shellcheck` al flujo de trabajo — habría señalado M4 y B1 de
forma automática.

---

## Orden de aplicación sugerido

1. **A2** — es un fallo silencioso, la peor categoría en esta herramienta.
2. **A1** — puede dejar una VM sin red y sin acceso.
3. **A3** — convierte un fallo común en un mensaje engañoso.
4. **M3, M2, M1** — baratos y quitan discrepancias entre panel y realidad.
5. **M4, B1, B2** — barrido mecánico, hacerlo de una vez con `shellcheck` delante.
6. **B3–B5** — decisiones de diseño, no urgencias.

Ninguno de los hallazgos afecta al flujo de despliegue normal (`/24`, sin IPv6),
que es el mayoritario y quedó verificado funcionando de extremo a extremo.
