# proxmox-vm-deployer

Instalador interactivo para desplegar VMs en **Proxmox VE** a partir de imágenes
cloud (`cloud-init`). Pensado para funcionar en **cualquier nodo Proxmox** —
standalone o cluster — sin hardcodear nada del hardware ni de la red del nodo
donde se probó.

Soporta **Debian 12/13** y **Ubuntu 20.04/22.04/24.04** (imágenes oficiales
genericcloud / cloud images, verificadas por checksum).

---

## ⚡ Quick install (one-liner)

Desde la consola del nodo Proxmox (como `root`):

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/proxmox-vm-deployer/master/deploy-vm.sh -o /root/deploy-vm.sh && chmod +x /root/deploy-vm.sh && /root/deploy-vm.sh
```

Descarga la última versión a `/root/deploy-vm.sh`, la hace ejecutable y arranca
el asistente. Deja el script en `/root/` para reutilizarlo (`/root/deploy-vm.sh`).

> El asistente es **interactivo**, así que no uses `curl ... | bash`: el pipe
> ocupa `stdin` y los menús (`read`) dejan de leer el teclado. Descarga primero
> (como arriba) o, si prefieres no dejar copia en disco, usa sustitución de
> proceso, que conserva `stdin` como la terminal:
>
> ```bash
> bash <(curl -fsSL https://raw.githubusercontent.com/mtandazo35/proxmox-vm-deployer/master/deploy-vm.sh)
> ```

---

## Qué hace, paso a paso

El asistente (`deploy-vm.sh`) recorre estas fases:

1. **Selección de SO y descarga** — elige Debian 12/13 o Ubuntu 20.04/22.04/24.04.
   La imagen oficial se descarga a `/var/lib/vz/template/iso/` (a un archivo
   `.part` que solo se renombra al completarse, para que una descarga
   interrumpida jamás quede en caché como imagen "válida") y se **verifica
   contra el checksum oficial** del upstream (SHA512 Debian / SHA256 Ubuntu).
   Si la caché quedó obsoleta porque upstream publicó una build nueva, se
   re-descarga sola; si una descarga fresca no matchea, se aborta (posible
   corrupción o alteración). También se lee el **tamaño virtual** de la imagen
   con `qemu-img info` — ese es el disco mínimo aceptado después (un
   `qm resize` nunca puede encoger).
2. **Detección de CPU** — `cpu=host` si el nodo es standalone (máximo
   rendimiento); `x86-64-v2-AES` si existe `/etc/pve/corosync.conf` (cluster),
   para no romper la migración en vivo entre nodos con CPUs distintas.
3. **Storage del disco** — lista solo los storages de imágenes activos del
   nodo, con espacio libre. Detecta si el medio es SSD/NVMe para añadir `ssd=1`
   (ver "Detección genérica" abajo).
4. **Storage de snippets** — elige el primer storage tipo `dir/nfs/cifs/cephfs`
   y, si no tiene `snippets` habilitado, lo **añade preservando el content
   existente** (leído de la API — jamás se reconstruye la lista, ver v8.1).
5. **VMID y nombre** — propone el siguiente ID libre (`/cluster/nextid`) y
   verifica que el elegido no exista **en todo el cluster** (VMs y CTs de
   cualquier nodo, vía `/cluster/resources`). El nombre se valida como
   hostname RFC (1-63 chars, letras/dígitos/guión).
6. **Autenticación** — tres modos:
   - `1` solo root + contraseña,
   - `2` solo clave SSH (`PermitRootLogin prohibit-password`,
     `PasswordAuthentication no`),
   - `3` clave SSH + contraseña (recomendado).
   La contraseña se hashea **SHA-512 con `mkpasswd` vía stdin** (nunca pasa
   por argv ni queda en texto plano en el YAML). Cada clave SSH pegada se
   valida con `ssh-keygen -lf` — una clave truncada o con typo se rechaza en
   el momento, no cuando la VM ya es inaccesible.
7. **Red** — bridge (solo `vmbrN` reales: excluye `docker0`, `fwbr*` y los
   sub-bridges `vmbrXvY`), VLAN opcional (1-4094), IPv4/CIDR/gateway, IPv6
   opcional (validada con `python3 ipaddress`), y DNS (cada server validado
   como IP). Con máscara `/32` (gateway fuera de subred, típico en hosting)
   añade `on-link: true` automáticamente.
   Aquí se genera la **MAC fija** con OUI de Proxmox (`BC:24:11:xx:xx:xx`),
   re-generándola si colisiona con alguna VM/CT existente del cluster — es la
   pieza clave de la portabilidad de red (ver la sección del bug v8).
8. **Recursos** — RAM (mín. 512 MB), cores (activa multiqueue virtio-net
   `queues=N` si N>1) y disco (mín. = tamaño virtual de la imagen; verifica
   además el espacio libre real del storage).
9. **Resumen y confirmación** — muestra todo y pide confirmar (`s`/`si`/`sí`).
10. **Generación de YAMLs** — escribe dos snippets con `umask 077` (0600):
    - `user-data-<VMID>.yaml`: hostname/FQDN `.internal`, timezone
      `America/Guayaquil`, growpart, auth según el modo, sysctl IPv6 estático
      (`accept_ra=0`) si aplica, `package_update/upgrade`, paquetes
      (`qemu-guest-agent`, `curl`, `htop`, y `resolvconf` en Debian), DNS
      temporal por `bootcmd` (envuelto en `cloud-init-per instance`: corre
      **solo el primer boot**), y `runcmd` que configura DNS definitivo,
      sshd (`/etc/ssh/sshd_config.d/60-deploy.conf`, aplicado solo si
      `sshd -t` pasa) y — en Ubuntu — un override de netplan por MAC con
      `chmod 600`.
    - `network-data-<VMID>.yaml`: network-config v2 con `match: macaddress`,
      `accept-ra: false`, rutas IPv4/IPv6 y `on-link` cuando corresponde.
    Ambos se validan con PyYAML si está disponible (si falta el módulo se
    salta la validación, no se confunde con "YAML inválido").
11. **Despliegue** — `qm create` (virtio-scsi-single, `discard=on`,
    `iothread=1`, serial0 como consola, `onboot=1`, `--agent`, descripción
    autogenerada con IP/fecha/imagen), import del disco, `qm resize`,
    `qm start`, y espera hasta 600 s a que el **guest-agent responda** (la
    señal de que cloud-init terminó). Todo el detalle queda en
    `/var/log/proxmox-deploy/deploy_VM<ID>_<fecha>.log`.

### Rollback automático

`set -Eeuo pipefail` + `trap` en `INT TERM ERR EXIT`. Cualquier fallo o
Ctrl+C — **incluso dentro de funciones o en los pasos redirigidos al log** —
dispara una única pasada de limpieza: detiene y destruye la VM parcial
(`--purge`), borra los snippets generados y la descarga `.part`, e indica el
log exacto donde quedó el error. Si aún no se había creado nada, lo dice
explícitamente ("No se hicieron cambios en el nodo").

---

## Selección automática de mirror

Antes de descargar, el instalador **mide qué mirror responde más rápido desde
ese nodo** (sondas de 256 KB en paralelo, techo ~8 s) y usa el ganador tanto
para la imagen como para el archivo de checksums — ambos del *mismo* mirror,
porque si vinieran de mirrors con distinta sincronización el hash no cuadraría
y el script entraría en una re-descarga innecesaria.

**Por qué hace falta:** `cloud.debian.org` y `cdimage.debian.org` son
round-robin DNS sobre el mismo clúster. Cuando alguna de sus IPs está caída,
`wget` se engancha a la IP muerta y se queda **minutos** colgado sin mostrar
progreso (parece que "no descarga"). Los backends individuales del clúster
permiten esquivarla:

```
🌎 Midiendo mirrors para elegir el más rápido...
  gemmei.ftp.acc.umu.se            1577 ms
  laotzu.ftp.acc.umu.se            1576 ms
  saimei.ftp.acc.umu.se            2376 ms
  ✅ Mirror elegido: laotzu.ftp.acc.umu.se
```

(En esa corrida real, los dos frontends no respondieron y quedaron descartados
automáticamente.)

**Sobre "el mirror más cercano":** las imágenes cloud de Debian **no están
espejadas en América**. Se verificó contra la lista oficial de mirrors de
Debian: los espejos regionales (incluido `mirror.cedia.org.ec`, la red
académica de Ecuador, y los de Brasil/Argentina/EE.UU.) sirven `debian-cd`
(las ISOs) pero **no** el árbol `cloud/` — todos devuelven 404. El único
origen es el clúster de `ftp.acc.umu.se` (Suecia), así que lo mejor
alcanzable es elegir su backend más rápido, que es lo que hace el script.

Para **Ubuntu** no hay nada que medir: `cloud-images.ubuntu.com` ya es un CDN
con geo-routing que sirve desde el POP más cercano (por eso baja rápido), así
que con un solo candidato la sonda se salta y no cuesta tiempo.

## Detección genérica (no asume el hardware del nodo)

- **`cpu=`** — `host` en standalone; `x86-64-v2-AES` si hay
  `/etc/pve/corosync.conf` (baseline portable con AES-NI, compatible con
  migración en vivo en clusters heterogéneos).
- **`ssd=1`** — solo si se confirma. Resuelve el storage a sus discos físicos
  (`lvm`/`lvmthin` vía `pvs`, `dir` vía `findmnt` — incluido root-on-ZFS —,
  `zfspool` vía `zpool list`) y consulta `lsblk ROTA`. En storage remoto
  (NFS/CIFS/CephFS/RBD) no se puede saber y el flag se omite — nunca se asume.
- **Storage y bridge** — se listan los realmente disponibles/activos del nodo.
- **`queues=`** — multiqueue virtio-net cuando `cores > 1`.
- **Disco mínimo** — leído de la imagen real con `qemu-img info`, no
  hardcodeado (Debian 13 = 3 GB, Ubuntu noble = 3.5 GB, etc.).

---

## El bug de red que motivó la v8 (portabilidad)

El `network-config v2` emparejaba la interfaz del guest **por driver**:

```yaml
ethernets:
  eth0:
    match:
      driver: virtio*
```

…y el override de netplan de Ubuntu la fijaba por **nombre hardcodeado**
(`ens18`). Ninguna de las dos formas es portable:

- **`match: driver:`** es un concepto de netplan. Debian genericcloud **no trae
  netplan**: cloud-init renderiza a `systemd-networkd`/ENI (`ifupdown`) y ahí el
  match por driver **no se traduce**, así que la interfaz nunca recibe la
  configuración → la VM arranca **sin ruta ni internet** (cloud-init se queda
  colgado en `package_upgrade` porque no hay red, y el guest-agent nunca llega
  a instalarse).
- **`ens18` hardcodeado** solo acierta en los nodos donde el guest nombra así la
  NIC; con otra máquina/BIOS/imagen puede ser `enp6s18`, `eth0`, etc.

### El fix: emparejar por MAC

El instalador **genera una MAC fija** con el OUI de Proxmox (`BC:24:11`),
la fija en `net0` y empareja la interfaz por esa MAC — igual que hace el propio
Proxmox en su config nativa:

```yaml
ethernets:
  nic0:
    match:
      macaddress: "bc:24:11:xx:xx:xx"
```

El match por MAC se traduce correctamente a **cualquier renderer** (ENI de
Debian, systemd-networkd, netplan de Ubuntu) y no depende del nombre de la NIC
ni de renombrarla. Además la MAC se regenera si ya existe en alguna VM/CT del
cluster (los nodos con IPs/MACs gestionadas a mano a veces tienen duplicados).

Caso real: VM 109 `dns` (Debian 13) desplegada con la versión anterior quedó
sin internet por exactamente este motivo.

---

## Auditoría v8.1 — qué se corrigió y por qué

Auditoría completa del script, con cada hallazgo verificado empíricamente y
cubierto por la suite de pruebas (`tests/`). En orden de gravedad:

### Críticos

1. **El rollback no cubría fallos dentro de funciones.** `set -e` sin `-E` no
   hereda el trap `ERR` en funciones — y el 100% del script corre en
   funciones. Un fallo de `qm create`/`qm resize` (cuya salida además va
   redirigida al log) mataba el script **en silencio**: sin mensaje, sin
   limpieza, dejando VM parcial y snippets huérfanos. Fix: `set -Eeuo
   pipefail` + trap también en `EXIT` (los `exit 1` explícitos tampoco
   disparan `ERR`), con guard anti-doble-ejecución.
2. **El checksum de Ubuntu nunca se verificaba.** El archivo de sumas
   upstream lista la imagen con su nombre original
   (`noble-server-cloudimg-amd64.img`), pero el script la renombra en caché
   (`ubuntu-24.04-...`) y buscaba ese nombre → nunca había match → "saltando
   verificación" **siempre**, en los tres Ubuntus. Fix: buscar por el
   `basename` de la URL. (En Debian sí funcionaba porque el nombre coincide.)
3. **Un typo en el modo de autenticación creaba una VM inaccesible.** La
   opción no se validaba: con "4" o "33" no entraba ni en la rama de password
   ni en la de claves → VM sin password Y sin claves, sin acceso ni por
   consola serial. Fix: validar 1/2/3 en loop.
4. **Disco mínimo hardcodeado en 2 GB.** Las imágenes miden más (Debian 13 =
   3 GB, noble = 3.5 GB) y `qm resize` no puede encoger → el deploy fallaba
   (y por el punto 1, fallaba en silencio). Fix: mínimo = tamaño virtual real
   leído con `qemu-img info`.

### Medios

5. **`pvesm set --content` podía destrozar la config del storage.** Leía la
   columna *tipo* de `pvesm status` creyendo que era el content y reconstruía
   la lista desde una whitelist → podía dejar el storage solo con
   `snippets,images`, borrando `iso`, `vztmpl`, `backup`, `import` (PVE 8.2+)
   de la config del nodo. Fix: leer el content real de la API
   (`/storage/<id>`) y **solo añadir** `snippets` si falta; si no se puede
   leer, no tocar nada. *Si la versión vieja corrió en tu nodo, revisa
   `/etc/pve/storage.cfg` — los archivos no se pierden, pero los tipos de
   content pueden haber desaparecido del GUI.*
6. **VMID verificado solo en el nodo local.** En cluster, un ID usado en otro
   nodo pasaba el chequeo y `qm create` fallaba después. Fix:
   `/cluster/resources` (VMs y CTs de todos los nodos), con fallback local.
7. **Descarga parcial quedaba como caché "válida".** Un Ctrl+C al 60% dejaba
   el archivo troceado; con el punto 2, en Ubuntu se habría importado
   corrupto. Fix: descargar a `.part` y renombrar solo al completar.
8. **Claves SSH sin validar** (typo en modo 2 = VM inaccesible) → `ssh-keygen
   -lf` por clave. **DNS sin validar** (texto arbitrario acababa en dos YAMLs
   y en `--nameserver`) → cada server debe ser IPv4/IPv6 válida. **VLAN
   inválida abortaba** el script entero → ahora re-pregunta, como el resto.
9. **`bootcmd` corría en CADA arranque** y pisaba el `/etc/resolv.conf`
   definitivo (en Ubuntu destruía el symlink a systemd-resolved en cada
   reboot). Fix: `cloud-init-per instance` — solo el primer boot.
10. **MAC aleatoria sin chequeo de colisión** → se regenera si ya existe en
    `/etc/pve/nodes/*/{qemu-server,lxc}/`.

### Menores

- Índice de storage validado en loop (input basura rompía la aritmética).
- `chmod 600` del override de netplan (netplan ≥22.04 avisa de permisos).
- Solo bridges `vmbrN` en el selector (fuera `docker0` y similares).
- Timeout del guest-agent 300→600 s (con `package_upgrade` y mirror lento,
  300 s daba falsos "revisa cloud-init manualmente").
- La confirmación acepta `s`, `si` y `sí` (antes "si" cancelaba el deploy).
- `clear` tolerante sin TTY (vía ssh no interactivo `set -e` mataba el script
  en la primera línea).
- PyYAML ausente ya no se reporta como "YAML inválido".

---

## Suite de pruebas (`tests/run-tests.sh`)

Banco de pruebas de **55 aserciones** que corre en cualquier Debian SIN
Proxmox (se usó un VPS limpio). Los comandos PVE se **stubean** —
`qm`/`pvesh`/`pvesm`/`ip` falsos que no crean nada real pero registran sus
argumentos para asertar sobre ellos — mientras que descargas, checksums,
`mkpasswd`, `ssh-keygen`, `findmnt`/`lsblk` y PyYAML son **reales**. Incluso
`qemu-img` se sustituye por un parser del header qcow2 real (el virtual-size
está en el offset 24, big-endian), así el test del disco mínimo mide la
imagen de verdad.

| Run | Escenario | Qué prueba |
|-----|-----------|------------|
| A | Debian 13 · auth 3 · IPv6 · VLAN 800 | Checksum sha512, hash SHA-512 real, match por MAC, ruta `::/0`, `cloud-init-per`, rechazo de: VMID ocupado en cluster, auth inválida, clave SSH basura, VLAN 5000, DNS no-IP; filtro de bridges; `pvesm set` preservando content; `tag=`/`queues=`/`cpu host`; permisos 600 |
| B | Ubuntu 24.04 · solo clave · /32 | **Checksum sha256 por fin verificado**, disco mínimo 4 GB medido de la imagen, `on-link: true`, override netplan por MAC + chmod 600, `prohibit-password`, sin hash de password, sin multiqueue con 1 core |
| C | `qm resize` falla a mitad del deploy | **El rollback se ejecuta** (fix `set -E`), destruye la VM parcial y borra los snippets — antes moría en silencio |
| D | Opción de SO inválida | Abort temprano limpio: "No se hicieron cambios en el nodo" |

Para correrla:

```bash
scp deploy-vm.sh tests/run-tests.sh root@<host-debian>:/root/deploy-test/
ssh root@<host-debian> "apt-get install -y python3-yaml && bash /root/deploy-test/run-tests.sh"
```

Resultado esperado: `PASS: 55  FAIL: 0 — 🟢 TODAS LAS PRUEBAS PASARON`.
Descarga ~1 GB de imágenes reales la primera vez (quedan cacheadas en
`/var/lib/vz/template/iso/`).

---

## Uso

```bash
/root/deploy-vm.sh
```

Es interactivo. Al terminar imprime cómo entrar (`qm terminal <vmid>` /
`ssh root@<ip>`) y dónde quedó el log del despliegue
(`/var/log/proxmox-deploy/`).

## Notas

- Las imágenes cloud quedan cacheadas en el nodo entre despliegues (y se
  re-verifican por checksum en cada uso).
- El SO se instala con `qemu-guest-agent`; el instalador espera a que responda
  como confirmación de que cloud-init terminó.
- Los snippets generados (`user-data-*.yaml` con el hash del password) quedan
  con permisos 0600 en el storage de snippets del nodo.
- `.gitattributes` fuerza `eol=lf`: un CRLF hace que Linux responda
  `No such file or directory` al ejecutar el script.
