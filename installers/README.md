# Bootc storage installer

The two entrypoints deliberately keep native composefs and OSTree deployment flows separate. Both
installers erase one configured whole GPT disk, create a UEFI ESP, an XBOOTLDR-style `/boot`
partition, and a Btrfs root partition. They support optional LUKS2/TPM2 enrollment, root-backed
Btrfs state subvolumes, and named additional volumes. They do not generate `/etc/fstab` or
`/etc/crypttab`.

## Configuration

Common settings in `install.env.example` cover the target disk and image references, named storage
records, recovery output, the first user, kernel arguments, and working paths. The final labeled
sections contain settings specific to composefs (`bootloader` and `allow_missing_verity`) and
OSTree (`stateroot`). The environment file is sourced as trusted Bash code.

The installer reads a trusted Bash configuration and requires an explicit named
storage model. `vol_list` is an indexed list of unique shell identifiers. The
first three entries must be `vol_root`, `vol_boot`, and `vol_esp`; each name
must resolve to a global Bash associative array. Additional records follow.

Each record uses these fields:

* `action`: `create`, `retain`, or `relation`.
* `device`, `parent_disk`, `partition_number`, `partition_size`, `partition_type`,
  and `partition_label` describe media. Partition numbers are explicit and do
  not depend on list order.
* `mountpoint`, `fs`, `fs_label`, and `mount_options` describe the filesystem.
  A created filesystem requires an explicit `fs_label`; retained filesystems
  may use any filesystem supported by the kernel.
* `encryption` is `none`, `luks-create`, or `luks-open`. Encrypted creation
  requires `luks_name` and `luks_label`.
* `credential` is `none`, `prompt`, `file`, `ephemeral`, or `env`. A file
  credential requires `credential_file`; an environment credential reads and
  erases `lvc_<luks_name>`. Ephemeral credentials apply only to new LUKS
  records and are removed after TPM and recovery access have been enrolled.
* `subvol_action` is `none`, `select`, or `create`, with `subvol` naming a
  normalized Btrfs subvolume. `none` mounts the filesystem root, `select`
  requires an existing subvolume, and `create` creates it if absent.
* `tpm2`, `tpm2_pcrs`, and `recovery` configure per-record enrollment. Recovery
  requires TPM2 and `recovery_key_output_file`.

The root record is ordinary data, for example:

```bash
vol_list=(vol_root vol_boot vol_esp vol_data)
declare -A vol_root=(
  [action]=create [parent_disk]="$target_disk" [partition_number]=3
  [partition_size]=remainder [partition_type]=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
  [partition_label]=root [mountpoint]=/ [fs]=btrfs [fs_label]=root
  [mount_options]=compress=zstd,noatime [encryption]=none [credential]=none
  [subvol]=root [subvol_action]=create [phase]=predeploy
)
```

The boot record uses partition 2, `ext4`, mountpoint `/boot`, and filesystem
label `boot`; the ESP uses partition 1, `vfat`, mountpoint `/boot/efi`, and
filesystem label `boot_efi`. The example configuration contains complete
records for all three core filesystems and a fourth data record.

`separate_var`, `separate_home`, and `separate_opt` remain convenience switches.
When true, validation generates uniquely named root-backed relation records;
an explicit record at the same mountpoint is rejected. Relations use
`action=relation` and `backing=<record>` and never wipe or format their backing
filesystem. User records may not target `/`, `/boot`, `/boot/efi`, `/state`, or
`/sysroot` trees (the core records retain their fixed roles); backend-specific
reserved trees are rejected by the backend callback.

Lifecycle processing is shared for every record: normalize and validate,
resolve dependencies, partition and wipe, create/open LUKS, create or verify a
filesystem, handle Btrfs subvolumes, mount by mountpoint depth, migrate backend
content, and emit mount/LUKS kernel arguments. Resolved runtime values are kept
in reserved record keys such as `_source`, `_partition_device`, `_luks_uuid`,
and `_fs_uuid`.

## Architecture and lifecycle

The shared libraries divide ownership cleanly: `lib/common.sh` owns CLI parsing, callback dispatch,
orchestration, common validation, generic bootc arguments, and cleanup; `lib/storage.sh` owns
record validation and preparation of disks, filesystems, Btrfs subvolumes, LUKS, and mounts; and
`lib/state.sh` owns exact-path target preparation, migration, user setup, and SELinux relabeling.
The composefs and OSTree entrypoints own only backend paths, options, assets, and deployment lookup.

Sourcing `lib/common.sh` is side-effect-free: it defines functions and globals but does not parse
arguments, install traps, create directories, or start an installation. Each entrypoint defines
the same callback contract (`*_set_defaults`, `*_preflight`, `*_validate_mount_target`,
`*_build_bootc_args`, `*_append_external_var_karg`, `*_locate_deployment`, and `*_postprocess`).
Backend policy and assets stay in the backend entrypoint while storage, state, and orchestration
remain shared.

Preflight validates configuration, paths, commands, assets, records, mapper names, mount options,
and backend requirements before recovery output is initialized or any disk is erased. Cleanup
attempts reverse-order unmounts, mapper closes, and temporary-key removal, logs individual failures,
preserves the original failure status, and reports success only when cleanup succeeds. There are
no forced or lazy unmounts and no rollback machinery.

## Usage

1. Copy `install.env.example` to a private configuration file and edit it.
2. Set `target_disk` to a stable `/dev/disk/by-id/...` whole-disk path.
3. Run one backend with `-y` to affirm that configured disks may be erased:

```bash
sudo ./install-ostree.sh -c ./install.env -y
sudo ./install-composefs.sh -c ./install.env -y
```

Use `-t` for Bash `set -x`; this can expose passwords, hashes, recovery keys, and other sensitive
values. `rust_log` is exported as `RUST_LOG` only for bootc. Leave `source_imgref` empty when the
installer runs inside the image it should install; set it only for a different image and use a
containers/image transport-qualified reference such as `docker://quay.io/example/os:latest`.
The target image must already grant sudo access to `wheel`; plaintext user passwords are unsupported,
so configure `user_password_hash` or leave it empty to create a locked account.

Run the focused checks with Bash 5 or newer:

```text
bash -n installers/lib/*.sh installers/tests/*.sh
bash installers/tests/storage_architecture.sh
bash installers/tests/storage_mock.sh
```

## Backend behavior and layout

`install-composefs.sh` accepts `bootloader=grub` or `bootloader=systemd`, passes
`--composefs-backend`, and protects `/composefs` and `/state` from volume records. Its physical
`/var` is `/state/os/default/var`; an external filesystem targeting literal `/var` is mounted in
the initramfs below `/sysroot/state/os/default/var` before `bootc-root-setup.service`.

`install-ostree.sh` supports GRUB only, validates `stateroot`, passes `--stateroot`, and protects
`/ostree` from volume records. Its physical `/var` is `/ostree/deploy/$stateroot/var`; it preserves
the existing real-root `/var` strategy and emits `systemd.mount-extra` for literal `/var`.
OSTree deployment lookup uses `ostree admin --sysroot=... --print-current-dir`.

Partition and filesystem labels are intentionally lower case:

```text
GPT name boot_efi -> VFAT label boot_efi -> /boot/efi (rw)
GPT name boot     -> ext4 label boot      -> boot filesystem
GPT name root     -> [LUKS label root_luks] -> Btrfs label root
```

For composefs, the boot filesystem is mounted at `/sysroot/boot` read-write and exposed at `/boot`
through a read-only bind mount. The OSTree installer retains bootc's standard runtime boot mount
arrangement. The root filesystem always contains the configured root subvolume; generated
`separate_*` records select descendants at the backend-specific physical state path.

## TPM2 and recovery enrollment

TPM2 policy is configured per LUKS volume. Set `tpm2=true` and, optionally, `tpm2_pcrs` on a
record; set `recovery=true` to enroll a recovery key. Recovery enrollment is accepted only for a
TPM-enabled encrypted volume. When requested, `recovery_key_output_file` is required, replaced
with mode `0600`, and written as one `LUKS_UUID RECOVERY_KEY` record per volume. Generated keys are
tested before being recorded and are not written to normal logs.

`credential=ephemeral` is valid only for a newly created LUKS volume with TPM and recovery enabled.
The temporary password slot is removed only after both recovery and TPM enrollment succeed.
Interactive and supplied-password setups retain their password slots. `credential=env` reads and
erases `lvc_<luks_name>` during activation; do not use `-t` when credentials are present because
xtrace can expose sensitive values.

## Native QEMU test harness

The project-level `test-with-qemu.sh` harness supports native AArch64 and x86-64 QEMU on macOS
and Linux. Its default install mode downloads and verifies a Fedora CoreOS live ISO, creates the
installation disks and scratch storage, installs a caller-supplied bootc image, saves recovery
keys, and powers off. Run it again with `-r boot` to start the installed VM or use `-r all` to chain
both stages. Generated state defaults to `qemu-test/`.

The live installer service and its Podman container require UID 0 and the complete capability set.
The scratch disk is mounted at `/var/tmp` in the live system before Podman starts because bootc
mirrors host `/var/tmp` during installation. The example image enables `systemd-networkd` and
`systemd-resolved` through the checked-in preset and wired-network fixture.

```bash
./test-with-qemu.sh -i ghcr.io/example/os:tag
./test-with-qemu.sh -r boot
```

Checked-in configurations exercise encrypted root, TPM2 PCR 7 and recovery enrollment,
ephemeral-key cleanup, encrypted Btrfs/XFS records, and the administrative user on each backend.
Both commands require a backend-compatible CI-built image reference; the harness does not consume
locally built images. Existing VM state is never replaced unless `-f` is supplied. See
`./test-with-qemu.sh -h` for the complete CLI; use `-q` or `INSTALLER_TRACE=false` for quieter
output.

Existing-volume regressions use an optional trusted pre-install hook. `-H FILE` (or
`QEMU_PREINSTALL_HOOK`) copies the executable into the live guest and runs it after target and
extra disks are checked but before Podman invokes the installer. It receives target, extra, and
scratch by-id paths as positional arguments and the corresponding `QEMU_PREINSTALL_*` variables.
For composefs existing LUKS2+Btrfs `/var`:

```bash
./test-with-qemu.sh -r all -C test-configs/qemu-existing-composefs.env \
  -H test-configs/qemu-hooks/prepare-existing-composefs-var.sh \
  -i ghcr.io/example/os:tag
```

For OSTree existing LUKS2+XFS `/opt`:

```bash
./test-with-qemu.sh -r all -b ostree -C test-configs/qemu-existing-ostree.env \
  -H test-configs/qemu-hooks/prepare-existing-ostree-opt.sh \
  -i ghcr.io/example/os:tag
```

After boot, verify recovery records, `findmnt /var` or `findmnt /opt`, and the seed marker. The
fixture's seed marker must remain while image content replaces its conflict marker. Existing-volume
hooks generate credentials in the guest runtime directory and do not commit secrets.

## Removing a backend

Backend support is intentionally removable by ownership boundary. To remove OSTree support, delete
`install-ostree.sh`, its labeled documentation/configuration section, and OSTree backend files. To
remove composefs support, delete `install-composefs.sh`, `backends/composefs/`, and its labeled
documentation/configuration section. Shared libraries retain only backend-neutral behavior.

`Containerfile.ostree` and image building are separate from installer backend support. The
Containerfile and its image-building flow are unchanged by this installer refactor.

## Requirements and constraints

- Run from a privileged bootc-capable installation environment with udev active.
- Required tools include bootc, sgdisk, cryptsetup, btrfs-progs, dosfstools, e2fsprogs,
  shadow-utils, util-linux, and policycoreutils when SELinux relabeling is needed. XFS creation
  additionally requires xfsprogs; TPM enrollment requires `systemd-cryptenroll` and a usable TPM2.
- `systemd.mount-extra=` requires systemd 254 or newer in the installed image and initramfs.
- Native composefs remains experimental in this bootc revision. Native composefs systemd-boot
  requires the image's kernel/UKI and systemd-boot assets; systemd-boot payloads are installed
  directly on the ESP while ext4 `/boot` remains available to the GRUB path.
- Global filesystem and GPT labels must not collide with devices belonging to another attached disk.
