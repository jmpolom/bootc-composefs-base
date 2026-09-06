# Tailored bootc filesystem installers

The two entrypoints deliberately keep the native composefs and OSTree deployment flows separate.
Both installers erase one configured whole GPT disk, create an ESP, an XBOOTLDR-style `/boot`
partition, and a Btrfs root partition. They support optional LUKS2/TPM2 enrollment, root-backed
Btrfs state subvolumes, and additional stateful mounts. They do not generate `/etc/fstab` or
`/etc/crypttab`.

## Configuration

Common settings in `install.env.example` come first: the target disk and image references, disk
sizes, root encryption and enrollment, recovery output, mount options, indexed extra-mount arrays,
the first user, kernel arguments, and working paths. The final labeled sections contain settings
specific to composefs (`bootloader` and `allow_missing_verity`) and OSTree (`stateroot`). Do not add
an `existing` setting: the current installer lifecycle is intentionally limited to preparing its
new installation storage and configuring the selected deployment.

Mount-option settings describe newly created storage. A colon is rejected where an option is
serialized by `systemd.mount-extra` because that argument uses `WHAT:WHERE:FSTYPE:OPTIONS`; it is
not a general filesystem-option allowlist. Each `extra_mount_points` value is a literal absolute
installed-tree target. It is never rewritten below `/var`, so `/home`, `/opt`, `/srv`, and `/data`
remain those exact targets. An existing directory is used, a missing directory and all parents are
created, and an image symlink or other non-directory is rejected unchanged without replacement,
unlinking, or renaming it.

The three legacy switches are normalized before indexed-array validation. For a backend physical
state path `P`, their exact generated records are:

| Switch | Device | Target | Filesystem/label | Options |
| --- | --- | --- | --- | --- |
| `separate_var=true` | `/dev/disk/by-label/root` | `/var` | `btrfs` / `root` | `subvol=root${P},$state_mount_options` |
| `separate_home=true` | `/dev/disk/by-label/root` | `/var/home` | `btrfs` / `root` | `subvol=root${P}/home,$state_mount_options` |
| `separate_opt=true` | `/dev/disk/by-label/root` | `/var/opt` | `btrfs` / `root` | `subvol=root${P}/opt,$state_mount_options` |

The generated records also set `extra_mount_encrypted`, `extra_mount_tpm2`, and
`extra_mount_tpm2_recovery` to `false`, and `extra_mount_luks_names` and
`extra_mount_tpm2_pcrs` to empty. `P` is `/state/os/default/var` for composefs and
`/ostree/deploy/$stateroot/var` for OSTree, so for example composefs `separate_home` selects
`subvol=root/state/os/default/var/home`, while OSTree selects
`subvol=root/ostree/deploy/$stateroot/var/home`. Explicit records are retained and generated
records are inserted immediately before the first explicit descendant that needs the generated
parent; otherwise the generated record is appended after the highest defined index. This keeps
unrelated explicit records in their original relative order and preserves sparse array holes for
validation. An explicit record using the same literal target as a true switch is rejected; the same
complete root-backed record written explicitly has identical behavior.

## Architecture and lifecycle

The final implementation has three shared libraries and two backend entrypoints:

- `lib/common.sh` owns the CLI, common defaults, callback dispatch, orchestration, common
  validation, generic bootc arguments, and cleanup. It sources the other two libraries.
- `lib/storage.sh` owns shortcut normalization, storage-array and mount-option validation, and
  preparation of disks, filesystems, Btrfs subvolumes, LUKS, and mounts.
- `lib/state.sh` owns exact-path target preparation, state migration, extra-mount population, the
  first-user setup, and SELinux relabeling.
- `install-composefs.sh` owns composefs paths, options, services, assets, and post-install work;
  `install-ostree.sh` owns OSTree paths, options, and deployment lookup.

Sourcing `lib/common.sh` is sourceable and side-effect-free: it defines functions and globals but
does not parse arguments, install traps, create directories, or start an installation. Each
entrypoint defines the same callback contract:
`<backend>_set_defaults`, `<backend>_preflight`, `<backend>_validate_mount_target`,
`<backend>_build_bootc_args`, `<backend>_append_external_var_karg`,
`<backend>_locate_deployment`, and `<backend>_postprocess`. The shared runner calls these through
validated callback names; backend policy and assets stay in the backend entrypoint while storage,
state, and orchestration stay shared.

Preflight validates configuration, paths, commands, assets, arrays, mapper names, mount options,
and backend requirements before recovery output is initialized or any disk is erased. Secret
operations temporarily disable Bash xtrace and restore its prior state, so recovery keys and
password hashes are not exposed by `-t`. Cleanup attempts every reverse-order unmount and mapper
close plus temporary-key removal, logs individual failures, preserves an original failure status,
and reports success only when cleanup succeeds. There are no forced/lazy unmounts, unspecified
retries, rollback machinery, or general existing-filesystem lifecycle in scope. Additional
whole-disk records are newly created storage; root-backed normalized records create/reuse only
their selected Btrfs subvolumes within the newly created root filesystem.

## Usage

1. Copy `install.env.example` to a private configuration file and edit it.
2. Set `target_disk` to a stable `/dev/disk/by-id/...` whole-disk path.
3. Run one backend with `-y` to affirm that `wipefs` and `sgdisk --zap-all` may erase the target:

```bash
sudo ./install-ostree.sh -c ./install.env -y
sudo ./install-composefs.sh -c ./install.env -y
```

Use `-t` for Bash `set -x`. `rust_log` is exported as `RUST_LOG` only for the bootc process; for
example, `rust_log=bootc=debug` enables bootc debug logs.

Leave `source_imgref` empty when the installer runs inside the image that it should install. In that
mode bootc discovers the running container through Podman, so invoke it from a rootful, privileged
container with the host PID namespace (`--pid=host`). Set `source_imgref` only when installing a
different image, and use a containers/image transport-qualified reference such as
`docker://quay.io/example/os:latest`.

The env file is sourced as trusted Bash code. By default each encrypted volume is initialized and
opened through interactive passphrase prompts. For automation, set `luks_ephemeral_key=true` to use
a per-volume random initializer stored only under the installer's runtime directory, or set
`luks_password_file` to use and retain the same supplied password slot on every encrypted volume.
These settings are mutually exclusive. A plaintext user password remains unsupported; configure
`user_password_hash` with a crypt-format hash or leave it empty to create a locked account. The
target image must already grant sudo access to `wheel`.

## Backend behavior and layout

`install-composefs.sh` accepts `bootloader=grub` or `bootloader=systemd`, passes
`--composefs-backend`, and protects `/composefs` and `/state` from extra mounts. Its physical
`/var` is `/state/os/default/var`; an external extra filesystem targeting literal `/var` is mounted
in the initramfs below `/sysroot/state/os/default/var` before `bootc-root-setup.service`.

`install-ostree.sh` supports GRUB only, validates `stateroot`, passes `--stateroot`, and protects
`/ostree` from extra mounts. Its physical `/var` is
`/ostree/deploy/$stateroot/var`; it preserves the existing real-root `/var` strategy and uses
`systemd.mount-extra` for an external `/var` filesystem. OSTree deployment lookup uses
`ostree admin --sysroot=... --print-current-dir`.

Partition and filesystem labels are intentionally lower case:

```text
GPT name boot_efi -> VFAT label boot_efi -> /boot/efi (rw)
GPT name boot     -> ext4 label boot      -> boot filesystem
GPT name root     -> [LUKS label root_luks] -> Btrfs label root
```

For composefs installations, the boot filesystem is mounted at `/sysroot/boot` read-write and is
exposed at `/boot` through a read-only bind mount. The OSTree installer retains bootc's standard
runtime boot mount arrangement.

The root filesystem always contains a `root` subvolume. Root-backed normalized records select
subvolumes at the backend-specific physical `/var` path and its `home`/`opt` descendants. A true
`separate_var`, `separate_home`, or `separate_opt` switch is therefore equivalent to the exact
indexed record shown above; there is no later shortcut-specific path handling. Other literal
targets are prepared and mounted at their requested paths.

## Additional state disks

Additional mounts are parallel indexed arrays in the env file. The following three arrays are
required and must have equal lengths:

```bash
extra_mount_devices=(/dev/vdb /dev/vdc)
extra_mount_points=(/var/lib/containers /srv)
extra_mount_filesystems=(xfs btrfs)
```

Optional arrays at the same indexes are `extra_mount_encrypted`, `extra_mount_labels`,
`extra_mount_options`, `extra_mount_luks_names`, `extra_mount_tpm2`, `extra_mount_tpm2_pcrs`, and
`extra_mount_tpm2_recovery`. Supported filesystems are Btrfs, ext4, and XFS. Each entry identifies a
whole disk, which is wiped and formatted directly without a partition table. `-y` authorizes erasure
of the installation disk and all additional state disks.

Labels default to a lower-case form of the logical path and are truncated only to meet filesystem
limits. Runtime sources always use `/dev/disk/by-label/...`. Encrypted entries receive a LUKS2
label, a stable mapper name, and `rd.luks.uuid=`, `rd.luks.name=`, and `rd.luks.options=` arguments.

Existing image state is migrated from each requested literal target directory. `/var` and its
descendants are accessed below the backend's physical `/var`; every other allowed target is
accessed below the deployment configuration root. The requested path is never resolved through
live-image aliases. `/etc`, `/boot`, immutable `/usr` paths, backend storage paths, and API
filesystems are rejected.

For composefs, an external filesystem targeting `/var` is mounted during the initramfs below
`/sysroot/state/os/default/var`, explicitly before `bootc-root-setup.service`; composefs then
exposes it through its normal `/var` bind mount. OSTree preserves its existing real-root `/var`
strategy and emits `systemd.mount-extra` for the literal `/var` target. Other literal targets use
their requested paths in the generated mount arguments.

The scripts use bootc's actual `--boot-mount-spec` option. There is no
`--bootc-mount-spec` option in the checked-out bootc CLI. The composefs installer also installs
native systemd mount units that mount the ext4 boot filesystem by UUID at `/sysroot/boot` read-write,
expose it at `/boot` through a read-only bind mount, and mount the ESP by UUID at `/boot/efi`
read-write. The native `boot.mount` overrides the `/boot` unit generated from bootc's
`systemd.mount-extra=` kernel argument. The ESP is intentionally not also mounted at
`/sysroot/boot/efi`; bootc discovers it independently when servicing composefs updates.

Root and bootc state mounts otherwise use `/dev/disk/by-label/...`; optional mounts use
`systemd.mount-extra=` or `rd.systemd.mount-extra=` kernel arguments. Mount-extra fields have the
form `WHAT:WHERE:FSTYPE:OPTIONS`. Ordinary `systemd.mount-extra=` entries are prefixed with
`/sysroot` when processed by the initrd; `rd.systemd.mount-extra=` entries are initrd-only and use
their target path literally, so their installed-system targets explicitly begin with `/sysroot`.

For LUKS, the scripts add `rd.luks.uuid=`, `rd.luks.name=`, and
`rd.luks.options=...=x-initrd.attach`, while bootc gets the decrypted Btrfs filesystem through
`--root-mount-spec=/dev/disk/by-label/root`.

## TPM2 and recovery enrollment

TPM2 policy is configured per LUKS volume. Use `root_tpm2=true` for root, or the matching
`extra_mount_tpm2` array entry for an additional volume. This per-volume model adds three settings
per volume but permits different PCR and recovery policies for root and independently replaceable
state disks; global settings would make those common mixed-storage cases need exceptions.

`root_tpm2_pcrs` and `extra_mount_tpm2_pcrs` accept the `systemd-cryptenroll --tpm2-pcrs=` syntax.
Leave an entry empty to omit the option and adopt the installed systemd version's default. Set the
corresponding `root_tpm2_recovery` or `extra_mount_tpm2_recovery` value to `true` to enroll a recovery
key. Recovery enrollment is accepted only for a TPM-enabled encrypted volume.

When recovery enrollment is requested, `recovery_key_output_file` is required. The installer creates
or replaces it with mode `0600` and writes one whitespace-delimited record per volume:

```text
01234567-89ab-cdef-0123-456789abcdef bcdefghi-jklnrtuv-bcdefghi-jklnrtuv-bcdefghi-jklnrtuv-bcdefghi-jklnrtuv
```

The first column is the LUKS UUID and the second is the raw systemd recovery key. The installer tests
the generated key before recording it and does not write the raw key to normal logs. Store this file
securely.
`luks_ephemeral_key=true` requires recovery enrollment on every encrypted volume; after recovery and
TPM enrollment succeed, all temporary password slots are removed. Interactive and supplied-password
setups retain their password slots. TPM-enabled volumes receive `tpm2-device=auto` in their
volume-specific `rd.luks.options=` argument; other encrypted volumes continue to prompt at boot.

## Native QEMU test harness

The project-level `test-with-qemu.sh` harness supports native AArch64 and x86-64 QEMU on macOS and
Linux. Its default `install` mode downloads and verifies the latest Fedora CoreOS live ISO, creates
two encrypted Btrfs installation disks and a temporary XFS scratch disk, installs a caller-supplied
bootc image with the composefs/GRUB path, saves both recovery keys, and powers off. The scratch disk
is mounted at `/var/tmp` in the live VM before Podman starts so bootc's mirrored host temporary
storage has adequate capacity. Run the harness a second time with `-r boot` to start the installed
VM, or use `-r all` to chain both stages. All generated state defaults to `qemu-test/`.

The live installer service and its Podman container both require UID 0 and the complete capability
set; the test aborts before modifying disks if either layer is restricted. The harness mounts the
temporary-storage disk at `/var/tmp` in the live system and passes that mount into the installer
container. This is required because bootc mirrors `/var/tmp` from the host mount namespace during
install preparation; creating the directory or mounting scratch only inside the container is not
sufficient.

The example image enables `systemd-networkd` and `systemd-resolved` through
`00-bootc-networkd.preset`, which is copied into the image before those packages are installed so
their RPM preset processing applies the policy. `20-bootc-wired.network` requests DHCP on Ethernet
interfaces; QEMU's user-mode network then provides outbound NAT, DHCP, and DNS without an imperative
`systemctl enable` build step.

```bash
./test-with-qemu.sh -i ghcr.io/example/os:tag
./test-with-qemu.sh -r boot
```

The checked-in configurations exercise the encrypted root, TPM2 PCR 7 and recovery enrollment,
ephemeral-key cleanup, a root-backed `/var`, an encrypted TPM2/recovery-protected Btrfs extra
mount, and the administrative user on each backend. Use the composefs configuration with its
literal `/var/opt` descendant:

```bash
./test-with-qemu.sh -r all -b composefs -C test-configs/qemu-default.env -i ghcr.io/example/os:tag
```

Use the OSTree configuration with its literal `/opt` extra mount:

```bash
./test-with-qemu.sh -r all -b ostree -C test-configs/qemu-ostree.env -i ghcr.io/example/os:tag
```

The OSTree image's `/srv` is an image symlink to `/var/srv`, so `/opt` is used to exercise a
literal extra target without replacing or traversing that symlink. Both commands require a
backend-compatible CI-built image reference; the harness does not consume locally built images.

Existing VM state is never replaced unless `-f` is supplied to an install mode. See
`./test-with-qemu.sh -h` for the complete CLI and corresponding environment variables.

## Removing a backend

Backend support is intentionally removable by ownership boundary. To remove OSTree installer
support, delete `install-ostree.sh`, its labeled OSTree documentation and configuration section,
and the OSTree backend-specific files/configuration. To remove composefs installer support, delete
`install-composefs.sh`, `backends/composefs/`, and the labeled composefs documentation and
configuration section. The shared libraries retain only backend-neutral behavior.

`Containerfile.ostree` and image building are separate from installer backend support. The
Containerfile and its image-building flow are unchanged by this installer refactor; removing an
installer does not imply changing or removing that Containerfile or its build process.

## Requirements and constraints

- Run from a privileged bootc-capable installation environment with udev active.
- Required tools include bootc, sgdisk, cryptsetup, btrfs-progs, dosfstools, e2fsprogs, shadow-utils,
  util-linux, and policycoreutils when SELinux relabeling is needed. XFS entries additionally require
  xfsprogs. TPM enrollment additionally requires `systemd-cryptenroll` and a usable TPM2 device.
- `systemd.mount-extra=` requires systemd 254 or newer in the installed image and initramfs.
- The native composefs backend remains experimental in this bootc revision.
- Native composefs systemd-boot requires an image carrying the kernel/UKI and systemd-boot assets
  expected by bootc.
- The current native composefs implementation does not use XBOOTLDR for systemd-boot. It installs
  systemd-boot payloads directly on the ESP; the required ext4 `/boot` partition remains available
  and is used by the composefs GRUB path.
- Global filesystem and GPT labels must not collide with devices belonging to another attached disk.
- The scripts currently provide default Discoverable Partitions root GUIDs for x86-64 and AArch64;
  other architectures must set `root_partition_type_guid` explicitly.
