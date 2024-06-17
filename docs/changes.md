<!--
SPDX-FileCopyrightText: StorPool <support@storpool.com>
SPDX-License-Identifier: BSD-2-Clause
-->

# Changelog

All notable changes to the pve-storpool project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2024-06-17

### Fixes

- sp-watchdog-mux:
  - fixes in Makefile install 

## [0.3.0] - 2024-06-12

### Additions

- sp-watchdog-mux:
  - introduced as replacement for PVE's watchdog-mux service in order to avoid
    host reboots on PVE cluster quorum loss which may negatively impact
    the StorPool cluster

## [0.2.4] - 2024-03-29

### Fixes

- documentation:
    - correct the project's GitHub repository URL

### Additions

- plugin:
    - when attaching VM-related StorPool volumes to a Proxmox VE hypervisor,
      force-detach the volumes from any other hypervisors or StorPool clients except
      during a live migration
    - add the `PVE::HA::Resources::Custom::StorPoolPlugin` module to allow
      the Proxmox VE HA services to migrate VMs with StorPool-backed volumes
    - add a `Makefile` for easier installation

### Other changes

- documentation:
    - use `mkdocstrings` 0.24 with no changes
    - add configuration for the `publync` tool for easier publishing
- test suite:
    - add Tox environment tags for use with the `tox-stages` tool

## [0.2.3] - 2023-12-11

### Fixes

- plugin:
    - grow or shrink a volume as needed when reverting to a snapshot

## [0.2.2] - 2023-09-06

### Fixes

- plugin:
    - ignore already-deleted StorPool snapshots - ones with names starting with
      the asterisk character
    - correct the Perl prototype of the `sp_request()` internal function

### Additions

- plugin:
    - log the request method and URL, as well as part of the response, for
      all requests sent to the StorPool API, to the new
      `/var/log/storpool/pve-storpool-query.log` file.
      For the present this is unconditional, it may be made configurable
      in the future.

### Other changes

- plugin:
    - correct two typographical errors in source code comments
- documentation:
    - point to version 1.1.0 of the "Keep a Changelog" specification
- config validator:
    - add SPDX copyright and license tags to all the Rust source files
    - also keep the `Cargo.lock` file under version control
- test suite:
    - also run the `reuse` Tox environment by default
    - use reuse 2.x with no changes
    - ignore the `rust/target/` build directory in the SPDX tags check

## [0.2.1] - 2023-07-12

### Fixes

- plugin:
    - fix a race when resizing a locally-attached volume

### Additions

- config validator:
    - add an experimental Rust tool, not distributed yet, for validating
      the current configuration of StorPool volumes attached to Proxmox
      virtual machines

### Other changes

- documentation:
    - installation instructions:
        - note that the `pvedaemon`, `pveproxy`, and `pvestatd` services need to be
          restarted after installing the StorPool plugin's Perl source file
        - provide installation instructions for the Debian package of the StorPool
          Proxmox plugin
        - drop some sections that did not really serve a useful purpose
    - drop the to-do list, it is tracked elsewhere at StorPool

## [0.2.0] - 2023-06-01

### Incompatible changes

- plugin:
    - do not declare support for OpenVZ templates (the `vztmpl` content type)
    - use the StorPool `VolumeTemplatesStatus` (`template status`) API query to
      determine the amount of used and free disk space for each storage
    - use the Proxmox cluster name (as returned by the `pvesh get /cluster/status`
      command) as the value for the `pve-loc` StorPool volume and snapshot tag;
      no longer look at the `/etc/pve/storpool/proxmox.cfg` file
    - use the configuration of the StorPool block client (as obtained by
      the `storpool_confget` command) for access to the StorPool API;
      no longer look at the `/etc/pve/storpool/api.cfg` file
    - remove (and do not automatically set) the `path` property of the storage;
      this changes the way Proxmox invokes the plugin's methods in several ways,
      among them the correct operation of backing a VM up and restoring it

### Additions

- plugin:
    - partially implement the `list_images()` plugin method so that e.g.
      unreferenced disk images may be found when destroying a VM
- documentation:
    - add this changelog file

### Fixes

- plugin:
    - use the `name` field of the StorPool volumes instead of their `globalId`
      field, since the latter may change when the volume is reverted to
      a snapshot
    - when reverting a volume to a snapshot, always detach it from all the hosts
      it is currently attached to; Proxmox does not do that beforehand for
      a currently running VM
    - validate ("untaint" in Perl-speak) the total size and stored size of
      a volume so that it may be used when migrating a volume to a different
      storage from the web UI
    - do not try to parse the internal value "state" for the `pve-disk` tag when
      looking for an available number to use as a VM disk "ID"

### Other changes

- documentation:
    - installation instructions:
        - remove the mention of the `vztmpl` content type
    - update the to-do list

## [0.1.0] - 2023-05-28

### Started

- Initial pre-release

[Unreleased]: https://github.com/storpool/pve-storpool/compare/release/0.3.0...main
[0.3.0]: https://github.com/storpool/pve-storpool/compare/release/0.2.4...release%2F0.3.0
[0.2.4]: https://github.com/storpool/pve-storpool/compare/release/0.2.3...release%2F0.2.4
[0.2.3]: https://github.com/storpool/pve-storpool/compare/release/0.2.2...release%2F0.2.3
[0.2.2]: https://github.com/storpool/pve-storpool/compare/release/0.2.1...release%2F0.2.2
[0.2.1]: https://github.com/storpool/pve-storpool/compare/release/0.2.0...release%2F0.2.1
[0.2.0]: https://github.com/storpool/pve-storpool/compare/release/0.1.0...release%2F0.2.0
[0.1.0]: https://github.com/storpool/pve-storpool/releases/tag/release%2F0.1.0
