# Tailored bootc filesystem installers

These scripts deliberately keep the OSTree and native composefs deployment flows separate:

- `install-ostree.sh` installs the OSTree backend and requires GRUB.
- `install-composefs.sh` passes `--composefs-backend` and accepts `grub` or `systemd`.
- `lib/common.sh` contains only storage preparation and common post-install operations.

Both scripts erase one whole GPT disk, create an ESP, an XBOOTLDR-style `/boot` partition, and a
Btrfs root partition. They support optional LUKS2 encryption, optional `var`, `home`, and `opt`
Btrfs subvolumes, and additional whole disks for stateful mounts. They do not generate `/etc/fstab`
or `/etc/crypttab`.

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

## Layout

Partition and filesystem labels are intentionally lower case:

```text
GPT name boot_efi -> VFAT label boot_efi -> /boot/efi
GPT name boot     -> ext4 label boot      -> /boot
GPT name root     -> [LUKS label root_luks] -> Btrfs label root
```

The root filesystem always contains a `root` subvolume. Optional state subvolumes are created at
their final backend-specific paths, with lower-case basename labels `var`, `home`, and `opt`. In the
default case bootc retains its standard `/home -> /var/home`, `/opt -> /var/opt`,
`/root -> /var/roothome`, and `/usr/local -> /var/usrlocal` mappings. Separate `home` and `opt`
subvolumes are mounted at `/var/home` and `/var/opt`, preserving those mappings.

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

Existing image state is migrated for `/var` and its descendants and for the standard bootc aliases
under `/home`, `/opt`, `/root`, `/usr/local`, `/srv`, `/mnt`, and `/media`. Other stateful targets,
such as `/data`, are supported but begin empty because neither backend provides a persistent source
tree for them before first boot. `/etc`, `/boot`, immutable `/usr` paths, backend storage paths, and
API filesystems are rejected.

The scripts use bootc's actual `--boot-mount-spec` option. There is no
`--bootc-mount-spec` option in the checked-out bootc CLI. Root and boot use `/dev/disk/by-label/...`;
optional mounts use `systemd.mount-extra=` or `rd.systemd.mount-extra=` kernel arguments. systemd
documents that mount-extra fields have the form `WHAT:WHERE:FSTYPE:OPTIONS`, and that initrd mount
targets are rooted below `/sysroot`.

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

```bash
./test-with-qemu.sh -i ghcr.io/example/os:tag
./test-with-qemu.sh -r boot
```

Both disks are TPM2-enrolled; the extra disk defaults to `/var` and can be changed with `-p`. Existing
VM state is never replaced unless `-f` is supplied to an install mode. See `./test-with-qemu.sh -h`
for the complete CLI and corresponding environment variables.

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
