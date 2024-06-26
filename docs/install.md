<!--
SPDX-FileCopyrightText: StorPool <support@storpool.com>
SPDX-License-Identifier: BSD-2-Clause
-->

# Installing the StorPool Proxmox integration

## Install the StorPool storage plugin file

Perform these steps on all the Proxmox VE hosts which will need to access
StorPool-backed volumes and snapshots:

- Make sure the StorPool client (the `storpool_block` service) is
  installed on the Proxmox host.
- Point Apt at the StorPool Debian package repository for the `bullseye-backports`
  suite; put the following lines into
  the `/etc/apt/sources.list.d/storpool-backports.sources` file:
  ```
  Types: deb deb-src
  URIs: https://repo.storpool.com/public/contrib/debian/
  Suites: bullseye-backports
  Components: main
  Signed-By: /usr/share/keyrings/storpool-keyring.gpg
  ```
- Install the `pve-storpool` package:
  ``` sh
  apt install pve-storpool
  ```

## Check the status of the StorPool and Proxmox installation

- Make sure the StorPool client (the `storpool_block` service) is operational:
  ``` sh
  systemctl status storpool_block.service
  ```
- Make sure the StorPool configuration includes the API access variables:
  ``` sh
  storpool_confshow -e SP_API_HTTP_HOST SP_API_HTTP_PORT SP_AUTH_TOKEN SP_OURID
  ```
- Make sure the StorPool cluster sees this client as operational:
  ```
  storpool service list
  storpool client status
  ```
- Make sure the Proxmox cluster is operational and has a sensible name configured:
  ``` sh
  pvesh get /cluster/status
  pvesh get /cluster/status -output-format json | jq -r '.[] | select(.id == "cluster") | .name'
  ```

## Create a StorPool-backed Proxmox VE storage

Note: this part may be partly automated by a command-line helper tool.

- Choose a StorPool template to use for the storage entry:
  ``` sh
  storpool template list
  ```
- Create a storage entry, specifying the StorPool template to use and
  some additional tags to set on each StorPool volume and snapshot, e.g.
  specifying a QoS tier:
  ``` sh
  pvesm add \
    'storpool' \
    'sp-nvme' \
    -shared true \
    -content 'images,iso' \
    -extra-tags 'tier=high' \
    -template 'nvme'
  ```
- Make sure Proxmox VE can query the status of the created storage:
  ``` sh
  pvesm status
  ```

## Enable StorPool's HCI HA watchdog

When enabling StorPool's [replacement watchdog service](watchdog.md),
the host will be put in maintenance mode in the cluster, which will migrate
away all HA resources to another machine. After the watchdog service is
replaced, the host will be returned to online mode.

Replacement **must be done one host at a time**.

To enable the StorPool watchdog replacement on a host:
```sh
/usr/lib/storpool/set-pve-watchdog storpool
```

You can also revert to the default PVE watchdog service if necessary:
```sh
/usr/lib/storpool/set-pve-watchdog pve
```

If the chosen watchdog service is already enabled, the script will exit early.
You can verify the status of the StorPool and PVE watchdogs:
```sh
systemctl status sp-watchdog-mux.service
systemctl status watchdog-mux.service
```
The service that is currently disabled will be masked.