# proxmox-vm-deployer

Instalador interactivo para desplegar VMs en **Proxmox VE** a partir de imágenes
cloud (`cloud-init`). Pensado para funcionar en **cualquier nodo Proxmox**, sin
hardcodear nada del hardware donde se probó.

Soporta Debian 12/13 y Ubuntu 20.04/22.04/24.04 (genericcloud / cloud images).

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

## Qué hace

Es un asistente por consola (`deploy-vm.sh`) que:

1. Descarga (y cachea) la imagen cloud del SO elegido.
2. Pregunta VMID, nombre, modo de autenticación (clave SSH / password),
   red (bridge, VLAN, IPv4/IPv6, gateway, DNS) y recursos (CPU, RAM, disco).
3. Genera el `user-data` y el `network-config v2` de cloud-init como snippets.
4. Crea la VM con `qm`, importa el disco al storage correcto, arranca y espera
   a que el guest-agent responda (señal de que cloud-init terminó).

## Detección genérica (no asume el hardware del nodo de prueba)

- **`cpu=`** — `host` si el nodo es standalone (máximo rendimiento);
  `x86-64-v2-AES` si existe `/etc/pve/corosync.conf`, para no romper la
  migración en vivo en clusters con CPU heterogénea.
- **`ssd=1`** — solo si se confirma. Resuelve el storage a sus discos físicos
  (`lvm`/`lvmthin` vía `pvs`, `dir` vía `findmnt` — incluido root-on-ZFS —,
  `zfspool` vía `zpool list`) y consulta `lsblk ROTA`. En storage remoto
  (NFS/CIFS/CephFS/RBD) no se puede saber y el flag se omite.
- **Storage y bridge** — se listan los realmente disponibles en el nodo.
- **`queues=`** — multiqueue virtio-net cuando `cores > 1`.

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

El instalador ahora **genera un MAC fijo** con el OUI de Proxmox (`BC:24:11`),
lo fija en `net0` y empareja la interfaz por ese MAC — igual que hace el propio
Proxmox en su config nativa:

```yaml
ethernets:
  nic0:
    match:
      macaddress: "bc:24:11:xx:xx:xx"
```

El match por MAC se traduce correctamente a **cualquier renderer** (ENI de
Debian, systemd-networkd, netplan de Ubuntu) y no depende del nombre de la NIC
ni de renombrarla. Caso real: VM 109 `dns` (Debian 13) en el nodo
`GOBRAVCORP` (`131.196.14.44`), desplegada con la versión anterior, quedó sin
internet por exactamente este motivo.

## Uso

```bash
scp deploy-vm.sh root@<nodo-proxmox>:/root/
ssh root@<nodo-proxmox>
chmod +x /root/deploy-vm.sh
/root/deploy-vm.sh
```

Es interactivo. Al terminar imprime cómo entrar (`qm terminal <vmid>` /
`ssh root@<ip>`) y dónde quedó el log del despliegue.

## Robustez (v8.1)

Auditoría completa + suite de pruebas con stubs (`qm`/`pvesh`/`pvesm` falsos,
descargas y checksums reales). Correcciones principales:

- **`set -E` + trap en `EXIT`**: antes el trap ERR no se heredaba dentro de
  funciones — un fallo de `qm create`/`qm resize` moría en silencio sin
  rollback (la salida iba al log). Ahora todo camino de fallo limpia la VM
  parcial y los snippets.
- **Checksum de Ubuntu**: nunca se verificaba — el archivo de sumas upstream
  usa el nombre original (`noble-server-cloudimg-amd64.img`) y se buscaba el
  nombre renombrado de la caché. Ahora se busca por el basename de la URL.
- **Disco mínimo = tamaño virtual de la imagen** (leído con `qemu-img info`):
  `qm resize` no puede encoger; pedir 2 GB con una imagen de 3.5 GB fallaba.
- **Modo de autenticación validado**: un typo (ej. "4") creaba una VM sin
  password y sin claves — inaccesible. Las claves SSH pegadas se validan con
  `ssh-keygen -lf`; DNS, VLAN e índices de menú también se validan/reintentan.
- **`pvesm set --content` preserva el content real** del storage (leído de la
  API): antes reconstruía la lista desde una whitelist y podía borrar tipos
  (`import`, etc.) de la config del nodo.
- **VMID verificado a nivel cluster** (`/cluster/resources`), no solo local.
- **Descarga a `.part`** + rename al completar: una descarga interrumpida no
  queda en caché como imagen "válida".
- **MAC sin colisiones**: se regenera si ya existe en alguna VM/CT del cluster.
- `bootcmd` del DNS temporal envuelto en `cloud-init-per instance` (antes
  corría en cada boot y pisaba el resolv.conf definitivo), `chmod 600` del
  override de netplan, timeout del guest-agent 300→600 s, solo bridges `vmbrN`
  en el selector, y "si"/"sí" aceptados al confirmar.

## Notas

- Las imágenes cloud quedan cacheadas en el nodo entre despliegues.
- El SO se instala con `qemu-guest-agent`; el instalador espera a que responda
  como confirmación de que cloud-init terminó.
- `.gitattributes` fuerza `eol=lf`: un CRLF hace que Linux responda
  `No such file or directory` al ejecutar el script.
