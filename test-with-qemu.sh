#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

QEMU_ARCH=${QEMU_ARCH:-$(uname -m)}
RUN_MODE=${RUN_MODE:-install}
BOOTC_IMAGE=${BOOTC_IMAGE:-}
QEMU_WORK_DIR=${QEMU_WORK_DIR:-$SCRIPT_DIR/qemu-test}
FCOS_STREAM=${FCOS_STREAM:-stable}
FCOS_ISO=${FCOS_ISO:-}
INSTALLER_BACKEND=${INSTALLER_BACKEND:-composefs}
BOOTLOADER=${BOOTLOADER:-grub}
EXTRA_MOUNT_POINT=${EXTRA_MOUNT_POINT:-/var}
LUKS_PASSWORD_FILE=${LUKS_PASSWORD_FILE:-}
RECOVERY_KEY_FILE=${RECOVERY_KEY_FILE:-}
TARGET_DISK_SIZE=${TARGET_DISK_SIZE:-40G}
EXTRA_DISK_SIZE=${EXTRA_DISK_SIZE:-40G}
QEMU_MEMORY=${QEMU_MEMORY:-4G}
QEMU_CPUS=${QEMU_CPUS:-4}
FORCE=${FORCE:-false}

QEMU_ACCEL=${QEMU_ACCEL:-}
QEMU_DISPLAY=${QEMU_DISPLAY:-}
FIRMWARE_CODE=${FIRMWARE_CODE:-}
FIRMWARE_VARS_TEMPLATE=${FIRMWARE_VARS_TEMPLATE:-}
BOOT_MENU_DELAY_SECS=${BOOT_MENU_DELAY_SECS:-8}
GRUB_KERNEL_LINE_DOWNS=${GRUB_KERNEL_LINE_DOWNS:-2}
INSTALL_TIMEOUT_SECS=${INSTALL_TIMEOUT_SECS:-7200}
TPM_PCRS=${TPM_PCRS:-7}
LIVE_KARGS=${LIVE_KARGS:-ignition.firstboot ignition.platform.id=qemu}

QEMU_PID=
SWTPM_PID=
DOWNLOAD_TMP=

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install a bootc image in a native-architecture QEMU VM, or boot an existing test VM.

  -a ARCH     Native architecture: x86_64 or aarch64.       [QEMU_ARCH]
  -r MODE     Run mode: install, boot, or all.               [RUN_MODE]
  -i IMAGE    Bootc image; required for install and all.     [BOOTC_IMAGE]
  -w DIR      Working directory below the project root.      [QEMU_WORK_DIR]
  -s STREAM   Fedora CoreOS stream.                          [FCOS_STREAM]
  -I ISO      Use this Fedora CoreOS live ISO.               [FCOS_ISO]
  -b BACKEND  Installer backend: composefs or ostree.        [INSTALLER_BACKEND]
  -l LOADER   Bootloader: grub or systemd.                   [BOOTLOADER]
  -p PATH     Mount point for the encrypted extra disk.      [EXTRA_MOUNT_POINT]
  -P FILE     Retained LUKS password file for both disks.    [LUKS_PASSWORD_FILE]
  -k FILE     Host recovery-key output file.                 [RECOVERY_KEY_FILE]
  -d SIZE     Target qcow2 size.                             [TARGET_DISK_SIZE]
  -e SIZE     Extra qcow2 size.                              [EXTRA_DISK_SIZE]
  -m MEMORY   Guest memory.                                  [QEMU_MEMORY]
  -c CPUS     Guest CPU count.                               [QEMU_CPUS]
  -f          Replace existing mutable VM state.             [FORCE=true]
  -h          Show this help.

CLI options override environment variables, which override built-in defaults.
The default mode only installs and powers off. Use '-r boot' for the subsequent
first boot, or '-r all' to install and immediately start the installed system.

Additional environment-only overrides:
  QEMU_ACCEL, QEMU_DISPLAY, FIRMWARE_CODE, FIRMWARE_VARS_TEMPLATE,
  BOOT_MENU_DELAY_SECS, GRUB_KERNEL_LINE_DOWNS, INSTALL_TIMEOUT_SECS,
  TPM_PCRS, and LIVE_KARGS.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

parse_options() {
    local option
    while getopts ':a:r:i:w:s:I:b:l:p:P:k:d:e:m:c:fh' option; do
        case "$option" in
            a) QEMU_ARCH=$OPTARG ;;
            r) RUN_MODE=$OPTARG ;;
            i) BOOTC_IMAGE=$OPTARG ;;
            w) QEMU_WORK_DIR=$OPTARG ;;
            s) FCOS_STREAM=$OPTARG ;;
            I) FCOS_ISO=$OPTARG ;;
            b) INSTALLER_BACKEND=$OPTARG ;;
            l) BOOTLOADER=$OPTARG ;;
            p) EXTRA_MOUNT_POINT=$OPTARG ;;
            P) LUKS_PASSWORD_FILE=$OPTARG ;;
            k) RECOVERY_KEY_FILE=$OPTARG ;;
            d) TARGET_DISK_SIZE=$OPTARG ;;
            e) EXTRA_DISK_SIZE=$OPTARG ;;
            m) QEMU_MEMORY=$OPTARG ;;
            c) QEMU_CPUS=$OPTARG ;;
            f) FORCE=true ;;
            h)
                usage
                exit 0
                ;;
            :) die "option -$OPTARG requires an argument" ;;
            \?) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    (($# == 0)) || die "unexpected positional arguments: $*"
}

normalize_architecture() {
    case "$1" in
        arm64 | aarch64) printf '%s\n' aarch64 ;;
        amd64 | x86_64) printf '%s\n' x86_64 ;;
        *) return 1 ;;
    esac
}

absolute_existing_path() {
    local path=$1
    local directory basename
    directory=$(dirname -- "$path")
    basename=$(basename -- "$path")
    (cd -- "$directory" && printf '%s/%s\n' "$(pwd -P)" "$basename")
}

validate_configuration() {
    local host_arch host_os
    host_arch=$(normalize_architecture "$(uname -m)") || die "unsupported host architecture: $(uname -m)"
    QEMU_ARCH=$(normalize_architecture "$QEMU_ARCH") || die "unsupported architecture: $QEMU_ARCH"
    [[ $QEMU_ARCH == "$host_arch" ]] ||
        die "cross-architecture emulation is unsupported (host=$host_arch requested=$QEMU_ARCH)"

    host_os=$(uname -s)
    case "$host_os" in
        Darwin | Linux) ;;
        *) die "unsupported host operating system: $host_os" ;;
    esac
    HOST_OS=$host_os

    case "$RUN_MODE" in install | boot | all) ;; *) die "invalid run mode: $RUN_MODE" ;; esac
    case "$FCOS_STREAM" in stable | testing | next) ;; *) die "invalid Fedora CoreOS stream: $FCOS_STREAM" ;; esac
    case "$INSTALLER_BACKEND" in composefs | ostree) ;; *) die "invalid installer backend: $INSTALLER_BACKEND" ;; esac
    case "$BOOTLOADER" in grub | systemd) ;; *) die "invalid bootloader: $BOOTLOADER" ;; esac
    [[ ! ($INSTALLER_BACKEND == ostree && $BOOTLOADER != grub) ]] ||
        die "the OSTree installer only supports the GRUB bootloader"
    [[ $EXTRA_MOUNT_POINT == /* ]] || die "extra mount point must be absolute: $EXTRA_MOUNT_POINT"
    [[ $EXTRA_MOUNT_POINT != *$'\n'* ]] || die "extra mount point cannot contain a newline"
    [[ $QEMU_CPUS =~ ^[1-9][0-9]*$ ]] || die "guest CPU count must be a positive integer"
    [[ $BOOT_MENU_DELAY_SECS =~ ^[0-9]+$ ]] || die "BOOT_MENU_DELAY_SECS must be a non-negative integer"
    [[ $GRUB_KERNEL_LINE_DOWNS =~ ^[0-9]+$ ]] || die "GRUB_KERNEL_LINE_DOWNS must be a non-negative integer"
    [[ $INSTALL_TIMEOUT_SECS =~ ^[1-9][0-9]*$ ]] || die "INSTALL_TIMEOUT_SECS must be a positive integer"
    case "$FORCE" in true | false) ;; *) die "FORCE must be true or false" ;; esac
    [[ $RUN_MODE != boot || $FORCE == false ]] || die "-f is not valid in boot mode"
    if [[ $RUN_MODE != boot ]]; then
        [[ -n $BOOTC_IMAGE ]] || die "a bootc image is required for $RUN_MODE mode (-i or BOOTC_IMAGE)"
    fi

    if [[ -n $LUKS_PASSWORD_FILE ]]; then
        [[ -f $LUKS_PASSWORD_FILE && -r $LUKS_PASSWORD_FILE ]] ||
            die "LUKS password file is not readable: $LUKS_PASSWORD_FILE"
        LUKS_PASSWORD_FILE=$(absolute_existing_path "$LUKS_PASSWORD_FILE")
    fi
    if [[ -n $FCOS_ISO ]]; then
        [[ -f $FCOS_ISO && -r $FCOS_ISO ]] || die "Fedora CoreOS ISO is not readable: $FCOS_ISO"
        FCOS_ISO=$(absolute_existing_path "$FCOS_ISO")
    fi
}

initialize_paths() {
    case "$QEMU_WORK_DIR" in
        /*) ;;
        *) QEMU_WORK_DIR=$SCRIPT_DIR/$QEMU_WORK_DIR ;;
    esac
    mkdir -p "$QEMU_WORK_DIR"
    QEMU_WORK_DIR=$(cd -- "$QEMU_WORK_DIR" && pwd -P)
    [[ $QEMU_WORK_DIR == "$SCRIPT_DIR"/* ]] ||
        die "QEMU working directory must be below the project root: $SCRIPT_DIR"
    chmod 0700 "$QEMU_WORK_DIR"

    if [[ -z $RECOVERY_KEY_FILE ]]; then
        RECOVERY_KEY_FILE=$QEMU_WORK_DIR/recovery-keys.txt
    elif [[ $RECOVERY_KEY_FILE != /* ]]; then
        RECOVERY_KEY_FILE=$QEMU_WORK_DIR/$RECOVERY_KEY_FILE
    fi
    [[ ! -L $RECOVERY_KEY_FILE ]] || die "recovery-key output must not be a symlink: $RECOVERY_KEY_FILE"
    [[ ! -e $RECOVERY_KEY_FILE || -f $RECOVERY_KEY_FILE ]] ||
        die "recovery-key output must be a regular file: $RECOVERY_KEY_FILE"
    [[ -z $LUKS_PASSWORD_FILE || $RECOVERY_KEY_FILE != "$LUKS_PASSWORD_FILE" ]] ||
        die "recovery-key output must differ from the LUKS password file"
    mkdir -p "$(dirname -- "$RECOVERY_KEY_FILE")"

    TARGET_DISK=$QEMU_WORK_DIR/target.qcow2
    EXTRA_DISK=$QEMU_WORK_DIR/extra.qcow2
    NVRAM_FILE=$QEMU_WORK_DIR/nvram.fd
    LIVE_IGNITION=$QEMU_WORK_DIR/live.ign
    LIVE_WRAPPER=$QEMU_WORK_DIR/run-install.sh
    INSTALL_CONFIG=$QEMU_WORK_DIR/install.conf
    INSTALL_SERIAL_LOG=$QEMU_WORK_DIR/install-serial.log
    BOOT_SERIAL_LOG=$QEMU_WORK_DIR/boot-serial.log
    MONITOR_SOCKET=$QEMU_WORK_DIR/monitor.sock
    TPM_DIR=$QEMU_WORK_DIR/tpm
    TPM_SOCKET=$TPM_DIR/swtpm.sock
    TPM_LOG=$QEMU_WORK_DIR/swtpm.log
    GUEST_PERSISTENT_DIR=/etc/test-install-qemu-bootc
    GUEST_RUNTIME_DIR=/run/test-install-qemu-bootc
    GUEST_WRAPPER=/usr/local/sbin/test-install-qemu-bootc
    GUEST_INSTALL_CONFIG=$GUEST_PERSISTENT_DIR/install.conf
    GUEST_RECOVERY_FILE=$GUEST_RUNTIME_DIR/recovery-keys.txt
    GUEST_PASSWORD_FILE=$GUEST_PERSISTENT_DIR/luks-password
    RECOVERY_PORT_NAME=org.test-install-qemu-bootc.recovery
    RECOVERY_PORT=/dev/virtio-ports/$RECOVERY_PORT_NAME

    local qemu_path_value
    for qemu_path_value in "$QEMU_WORK_DIR" "$RECOVERY_KEY_FILE"; do
        [[ $qemu_path_value != *,* && $qemu_path_value != *$'\n'* ]] ||
            die "QEMU paths cannot contain commas or newlines: $qemu_path_value"
    done
    for qemu_path_value in "$TARGET_DISK" "$EXTRA_DISK" "$NVRAM_FILE"; do
        [[ -z $FCOS_ISO || $FCOS_ISO != "$qemu_path_value" ]] ||
            die "Fedora CoreOS ISO conflicts with mutable VM state: $FCOS_ISO"
        [[ -z $LUKS_PASSWORD_FILE || $LUKS_PASSWORD_FILE != "$qemu_path_value" ]] ||
            die "LUKS password file conflicts with mutable VM state: $LUKS_PASSWORD_FILE"
    done

    local qemu_path
    qemu_path=$(command -v "qemu-system-$QEMU_ARCH" 2>/dev/null || true)
    [[ -n $qemu_path ]] || die "required command is unavailable: qemu-system-$QEMU_ARCH"
    QEMU_SYSTEM=$qemu_path

    if [[ -z $QEMU_ACCEL ]]; then
        if [[ $HOST_OS == Darwin ]]; then
            QEMU_ACCEL=hvf
        else
            QEMU_ACCEL=kvm
        fi
    fi
    if [[ -z $QEMU_DISPLAY ]]; then
        if [[ $HOST_OS == Darwin ]]; then
            QEMU_DISPLAY=cocoa,show-cursor=on
        elif [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
            QEMU_DISPLAY=gtk,show-cursor=on
        else
            QEMU_DISPLAY=none
        fi
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_host_commands() {
    require_command qemu-img
    require_command swtpm
    require_command jq
    if [[ $RUN_MODE != boot ]]; then
        require_command base64
        require_command curl
        require_command socat
        if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
            die "required SHA-256 command is unavailable (sha256sum or shasum)"
        fi
    fi
    if [[ $HOST_OS == Linux && $QEMU_ACCEL == kvm && (! -r /dev/kvm || ! -w /dev/kvm) ]]; then
        die "KVM acceleration requested but /dev/kvm is unavailable; set QEMU_ACCEL explicitly to override"
    fi
}

firmware_from_manifests() {
    local qemu_bin qemu_prefix directory manifest record code vars
    qemu_bin=$(cd -- "$(dirname -- "$QEMU_SYSTEM")" && pwd -P)
    qemu_prefix=$(cd -- "$qemu_bin/.." && pwd -P)

    for directory in "$qemu_prefix/share/qemu/firmware" /usr/share/qemu/firmware /usr/local/share/qemu/firmware; do
        [[ -d $directory ]] || continue
        for manifest in "$directory"/*.json; do
            [[ -f $manifest ]] || continue
            record=$(jq -r --arg architecture "$QEMU_ARCH" '
                select(.mapping.device == "flash") |
                select([.targets[]?.architecture] | index($architecture)) |
                select(((.features // []) | index("secure-boot")) == null) |
                [.mapping.executable.filename, .mapping["nvram-template"].filename] | @tsv
            ' "$manifest" 2>/dev/null | head -n1)
            [[ -n $record ]] || continue
            code=${record%%$'\t'*}
            vars=${record#*$'\t'}
            if [[ -f $code && -f $vars ]]; then
                FIRMWARE_CODE=$code
                FIRMWARE_VARS_TEMPLATE=$vars
                return 0
            fi
        done
    done
    return 1
}

firmware_from_known_paths() {
    local pair code vars
    if [[ $QEMU_ARCH == aarch64 ]]; then
        for pair in \
            '/opt/homebrew/share/qemu/edk2-aarch64-code.fd|/opt/homebrew/share/qemu/edk2-arm-vars.fd' \
            '/usr/share/AAVMF/AAVMF_CODE.fd|/usr/share/AAVMF/AAVMF_VARS.fd' \
            '/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw|/usr/share/edk2/aarch64/vars-template-pflash.raw'
        do
            code=${pair%%|*}
            vars=${pair#*|}
            [[ -f $code && -f $vars ]] || continue
            FIRMWARE_CODE=$code
            FIRMWARE_VARS_TEMPLATE=$vars
            return 0
        done
    else
        for pair in \
            '/opt/homebrew/share/qemu/edk2-x86_64-code.fd|/opt/homebrew/share/qemu/edk2-i386-vars.fd' \
            '/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd' \
            '/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd'
        do
            code=${pair%%|*}
            vars=${pair#*|}
            [[ -f $code && -f $vars ]] || continue
            FIRMWARE_CODE=$code
            FIRMWARE_VARS_TEMPLATE=$vars
            return 0
        done
    fi
    return 1
}

resolve_firmware() {
    if [[ -n $FIRMWARE_CODE || -n $FIRMWARE_VARS_TEMPLATE ]]; then
        [[ -n $FIRMWARE_CODE && -n $FIRMWARE_VARS_TEMPLATE ]] ||
            die "FIRMWARE_CODE and FIRMWARE_VARS_TEMPLATE must be set together"
    else
        firmware_from_manifests || firmware_from_known_paths ||
            die "could not locate UEFI firmware; set FIRMWARE_CODE and FIRMWARE_VARS_TEMPLATE"
    fi
    [[ -r $FIRMWARE_CODE ]] || die "firmware code is not readable: $FIRMWARE_CODE"
    [[ -r $FIRMWARE_VARS_TEMPLATE ]] || die "firmware variables template is not readable: $FIRMWARE_VARS_TEMPLATE"
    [[ $FIRMWARE_CODE != *,* && $FIRMWARE_VARS_TEMPLATE != *,* ]] ||
        die "QEMU firmware paths cannot contain commas"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

resolve_fcos_iso() {
    if [[ -n $FCOS_ISO ]]; then
        [[ $FCOS_ISO != *,* && $FCOS_ISO != *$'\n'* ]] ||
            die "QEMU ISO paths cannot contain commas or newlines: $FCOS_ISO"
        return
    fi

    local metadata_url metadata_file metadata_tmp iso_url iso_sha iso_name actual_sha
    metadata_url=https://builds.coreos.fedoraproject.org/streams/$FCOS_STREAM.json
    metadata_file=$QEMU_WORK_DIR/fcos-$FCOS_STREAM.json
    metadata_tmp=$metadata_file.part.$$
    DOWNLOAD_TMP=$metadata_tmp
    log "Fetching Fedora CoreOS $FCOS_STREAM stream metadata"
    curl --fail --location --retry 3 --output "$metadata_tmp" "$metadata_url"
    mv -f -- "$metadata_tmp" "$metadata_file"
    DOWNLOAD_TMP=

    iso_url=$(jq -er --arg architecture "$QEMU_ARCH" \
        '.architectures[$architecture].artifacts.metal.formats.iso.disk.location' "$metadata_file") ||
        die "the $FCOS_STREAM stream has no live ISO for $QEMU_ARCH"
    iso_sha=$(jq -er --arg architecture "$QEMU_ARCH" \
        '.architectures[$architecture].artifacts.metal.formats.iso.disk.sha256' "$metadata_file") ||
        die "the $FCOS_STREAM stream did not publish an ISO checksum for $QEMU_ARCH"
    iso_name=${iso_url##*/}
    FCOS_ISO=$QEMU_WORK_DIR/$iso_name

    if [[ ! -f $FCOS_ISO ]]; then
        DOWNLOAD_TMP=$FCOS_ISO.part.$$
        log "Downloading $iso_name"
        curl --fail --location --retry 3 --output "$DOWNLOAD_TMP" "$iso_url"
        actual_sha=$(sha256_file "$DOWNLOAD_TMP")
        [[ $actual_sha == "$iso_sha" ]] || die "downloaded ISO checksum mismatch: $actual_sha"
        mv -f -- "$DOWNLOAD_TMP" "$FCOS_ISO"
        DOWNLOAD_TMP=
    fi

    actual_sha=$(sha256_file "$FCOS_ISO")
    [[ $actual_sha == "$iso_sha" ]] ||
        die "cached ISO checksum mismatch; remove the file and retry: $FCOS_ISO"
}

reset_install_state() {
    local existing=false
    [[ -e $TARGET_DISK ]] && existing=true
    [[ -e $EXTRA_DISK ]] && existing=true
    [[ -e $NVRAM_FILE ]] && existing=true
    [[ -d $TPM_DIR ]] && existing=true
    [[ -e $RECOVERY_KEY_FILE ]] && existing=true

    if [[ $existing == true && $FORCE != true ]]; then
        die "mutable VM state already exists in $QEMU_WORK_DIR; use -f to replace it or -r boot to start it"
    fi
    if [[ $FORCE == true ]]; then
        rm -f -- "$TARGET_DISK" "$EXTRA_DISK" "$NVRAM_FILE" "$LIVE_IGNITION" "$LIVE_WRAPPER" \
            "$INSTALL_CONFIG" "$INSTALL_SERIAL_LOG" "$BOOT_SERIAL_LOG" "$MONITOR_SOCKET" "$TPM_LOG" \
            "$RECOVERY_KEY_FILE"
        rm -rf -- "$TPM_DIR"
    fi

    mkdir -p "$TPM_DIR"
    chmod 0700 "$TPM_DIR"
    qemu-img create -f qcow2 "$TARGET_DISK" "$TARGET_DISK_SIZE" >/dev/null
    qemu-img create -f qcow2 "$EXTRA_DISK" "$EXTRA_DISK_SIZE" >/dev/null
    cp -- "$FIRMWARE_VARS_TEMPLATE" "$NVRAM_FILE"
    chmod u+w "$NVRAM_FILE"
}

validate_boot_state() {
    local path
    for path in "$TARGET_DISK" "$EXTRA_DISK" "$NVRAM_FILE"; do
        [[ -f $path ]] || die "boot mode requires existing VM state: $path"
    done
    [[ -d $TPM_DIR ]] || die "boot mode requires existing TPM state: $TPM_DIR"
}

data_url_from_file() {
    printf 'data:text/plain;charset=utf-8;base64,%s' "$(base64 <"$1" | tr -d '\n')"
}

create_installer_config() {
    local serial_console
    if [[ $QEMU_ARCH == aarch64 ]]; then
        serial_console=ttyAMA0,115200n8
    else
        serial_console=ttyS0,115200n8
    fi

    {
        printf 'target_disk=%q\n' /dev/disk/by-id/virtio-bootc-root
        printf 'source_imgref=%q\n' "$BOOTC_IMAGE"
        printf 'target_imgref=\n'
        printf 'work_root=%q\n' "$GUEST_RUNTIME_DIR"
        printf 'bootloader=%q\n' "$BOOTLOADER"
        printf 'root_encrypted=true\n'
        printf 'root_tpm2=true\n'
        printf 'root_tpm2_pcrs=%q\n' "$TPM_PCRS"
        printf 'root_tpm2_recovery=true\n'
        printf 'recovery_key_output_file=%q\n' "$GUEST_RECOVERY_FILE"
        if [[ -n $LUKS_PASSWORD_FILE ]]; then
            printf 'luks_ephemeral_key=false\n'
            printf 'luks_password_file=%q\n' "$GUEST_PASSWORD_FILE"
        else
            printf 'luks_ephemeral_key=true\n'
            printf 'luks_password_file=\n'
        fi
        printf 'extra_mount_devices=(%q)\n' /dev/disk/by-id/virtio-bootc-extra
        printf 'extra_mount_points=(%q)\n' "$EXTRA_MOUNT_POINT"
        printf 'extra_mount_filesystems=(btrfs)\n'
        printf 'extra_mount_encrypted=(true)\n'
        printf 'extra_mount_options=(compress=zstd,noatime)\n'
        printf 'extra_mount_tpm2=(true)\n'
        printf 'extra_mount_tpm2_pcrs=(%q)\n' "$TPM_PCRS"
        printf 'extra_mount_tpm2_recovery=(true)\n'
        printf 'extra_kargs=(console=tty0 %q)\n' "console=$serial_console"
        printf 'user_name=\n'
    } >"$INSTALL_CONFIG"
    chmod 0600 "$INSTALL_CONFIG"
}

create_live_wrapper() {
    local installer_name=install-$INSTALLER_BACKEND.sh
    {
        printf '#!/usr/bin/env bash\n'
        printf 'image_ref=%q\n' "$BOOTC_IMAGE"
        printf 'installer_name=%q\n' "$installer_name"
        printf 'install_config=%q\n' "$GUEST_INSTALL_CONFIG"
        printf 'runtime_dir=%q\n' "$GUEST_RUNTIME_DIR"
        printf 'recovery_file=%q\n' "$GUEST_RECOVERY_FILE"
        printf 'recovery_port=%q\n' "$RECOVERY_PORT"
        cat <<'EOF'
set -Eeuo pipefail

container_id=

finish() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $container_id ]]; then
        podman rm -f "$container_id" >/dev/null 2>&1
    fi
    if [[ -s $recovery_file ]]; then
        local remaining=30
        while [[ ! -c $recovery_port && $remaining -gt 0 ]]; do
            sleep 1
            remaining=$((remaining - 1))
        done
        if [[ -c $recovery_port ]]; then
            if ! cat "$recovery_file" >"$recovery_port"; then
                echo "Could not write recovery keys to the virtio port" >&2
                status=1
            fi
        else
            echo "Recovery-key virtio port did not appear" >&2
            status=1
        fi
    fi
    printf 'TEST_INSTALL_QEMU_BOOTC_RESULT=%d\n' "$status"
    sync
    systemctl --no-block poweroff
    exit "$status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Pulling $image_ref"
podman pull "$image_ref"
container_id=$(podman create "$image_ref")
mkdir -p "$runtime_dir/extracted"
podman cp "$container_id:/usr/libexec/bootc-installer/." "$runtime_dir/extracted/"
chmod 0755 "$runtime_dir/extracted/$installer_name"
"$runtime_dir/extracted/$installer_name" -c "$install_config" -y
[[ $(wc -l <"$recovery_file") -eq 2 ]] || {
    echo "Expected two recovery-key records" >&2
    exit 1
}
EOF
    } >"$LIVE_WRAPPER"
    chmod 0700 "$LIVE_WRAPPER"
}

create_live_ignition() {
    local wrapper_source config_source password_source=
    wrapper_source=$(data_url_from_file "$LIVE_WRAPPER")
    config_source=$(data_url_from_file "$INSTALL_CONFIG")
    if [[ -n $LUKS_PASSWORD_FILE ]]; then
        password_source=$(data_url_from_file "$LUKS_PASSWORD_FILE")
    fi

    {
        cat <<EOF
{
  "ignition": { "version": "3.4.0" },
  "storage": {
    "files": [
      {
        "path": "$GUEST_WRAPPER",
        "mode": 493,
        "overwrite": true,
        "contents": { "source": "$wrapper_source" }
      },
      {
        "path": "$GUEST_INSTALL_CONFIG",
        "mode": 384,
        "overwrite": true,
        "contents": { "source": "$config_source" }
      }
EOF
        if [[ -n $password_source ]]; then
            cat <<EOF
      ,{
        "path": "$GUEST_PASSWORD_FILE",
        "mode": 384,
        "overwrite": true,
        "contents": { "source": "$password_source" }
      }
EOF
        fi
        cat <<EOF
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "test-install-qemu-bootc.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Install the requested bootc image in the QEMU test VM\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=$GUEST_WRAPPER\nStandardOutput=journal+console\nStandardError=journal+console\n\n[Install]\nWantedBy=multi-user.target\n"
      }
    ]
  }
}
EOF
    } >"$LIVE_IGNITION"
    chmod 0600 "$LIVE_IGNITION"
}

start_swtpm() {
    rm -f -- "$TPM_SOCKET"
    swtpm socket \
        --tpmstate "dir=$TPM_DIR" \
        --ctrl "type=unixio,path=$TPM_SOCKET" \
        --tpm2 \
        --log "file=$TPM_LOG,level=20" &
    SWTPM_PID=$!
    wait_for_socket "$TPM_SOCKET" 30
}

wait_for_socket() {
    local socket_path=$1
    local timeout=$2
    local waited=0
    while [[ ! -S $socket_path ]]; do
        if [[ -n $SWTPM_PID ]] && ! kill -0 "$SWTPM_PID" >/dev/null 2>&1; then
            die "swtpm exited before creating its socket; see $TPM_LOG"
        fi
        sleep 1
        waited=$((waited + 1))
        ((waited < timeout)) || die "timed out waiting for socket: $socket_path"
    done
}

stop_swtpm() {
    if [[ -n $SWTPM_PID ]]; then
        kill "$SWTPM_PID" >/dev/null 2>&1 || true
        wait "$SWTPM_PID" >/dev/null 2>&1 || true
        SWTPM_PID=
    fi
}

base_qemu_args() {
    QEMU_ARGS=(
        -name bootc-composefs-test
        -accel "$QEMU_ACCEL"
        -cpu host
        -smp "$QEMU_CPUS"
        -m "$QEMU_MEMORY"
        -display "$QEMU_DISPLAY"
        -device virtio-gpu-pci
        -device qemu-xhci
        -device usb-kbd
        -device usb-tablet
        -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE_CODE"
        -drive "if=pflash,format=raw,file=$NVRAM_FILE"
        -drive "file=$TARGET_DISK,if=none,format=qcow2,id=rootdisk"
        -device 'virtio-blk-pci,drive=rootdisk,serial=bootc-root,bootindex=2'
        -drive "file=$EXTRA_DISK,if=none,format=qcow2,id=extradisk"
        -device 'virtio-blk-pci,drive=extradisk,serial=bootc-extra'
        -netdev 'user,id=net0,hostname=bootc-test'
        -device 'virtio-net-pci,netdev=net0'
        -chardev "socket,id=chrtpm,path=$TPM_SOCKET"
        -tpmdev 'emulator,id=tpm0,chardev=chrtpm'
        -monitor "unix:$MONITOR_SOCKET,server=on,wait=off"
    )
    if [[ $QEMU_ARCH == aarch64 ]]; then
        QEMU_ARGS=(-machine 'virt,highmem=on' "${QEMU_ARGS[@]}" -device 'tpm-tis-device,tpmdev=tpm0')
    else
        QEMU_ARGS=(-machine q35 "${QEMU_ARGS[@]}" -device 'tpm-tis,tpmdev=tpm0')
    fi
}

add_serial_console() {
    local serial_log=$1
    QEMU_ARGS+=(
        -chardev "stdio,id=serialconsole,signal=off,logfile=$serial_log,logappend=off"
        -serial chardev:serialconsole
    )
}

start_qemu_install() {
    rm -f -- "$MONITOR_SOCKET" "$INSTALL_SERIAL_LOG" "$RECOVERY_KEY_FILE"
    base_qemu_args
    QEMU_ARGS+=(
        -drive "file=$FCOS_ISO,media=cdrom,readonly=on,if=none,id=installcd"
        -device virtio-scsi-pci
        -device 'scsi-cd,drive=installcd,bootindex=1'
        -boot 'menu=on'
        -fw_cfg "name=opt/com.coreos/config,file=$LIVE_IGNITION"
        -device virtio-serial-pci
        -chardev "file,id=recovery,path=$RECOVERY_KEY_FILE"
        -device "virtserialport,chardev=recovery,name=$RECOVERY_PORT_NAME"
    )
    add_serial_console "$INSTALL_SERIAL_LOG"
    "$QEMU_SYSTEM" "${QEMU_ARGS[@]}" &
    QEMU_PID=$!
    wait_for_socket "$MONITOR_SOCKET" 30
}

start_qemu_boot() {
    rm -f -- "$MONITOR_SOCKET" "$BOOT_SERIAL_LOG"
    base_qemu_args
    QEMU_ARGS+=(
        -boot 'order=c'
    )
    add_serial_console "$BOOT_SERIAL_LOG"
    "$QEMU_SYSTEM" "${QEMU_ARGS[@]}" &
    QEMU_PID=$!
    wait_for_socket "$MONITOR_SOCKET" 30
}

hmp_command() {
    printf '%s\n' "$1" | socat -T 1 - "UNIX-CONNECT:$MONITOR_SOCKET" >/dev/null
}

hmp_sendkey() {
    hmp_command "sendkey $1"
    sleep 0.1
}

hmp_send_text() {
    local value=$1 index character
    index=0
    while ((index < ${#value})); do
        character=${value:index:1}
        case "$character" in
            ' ') hmp_sendkey spc ;;
            '.') hmp_sendkey dot ;;
            '=') hmp_sendkey equal ;;
            '-') hmp_sendkey minus ;;
            [a-z0-9]) hmp_sendkey "$character" ;;
            *) die "unsupported character for QEMU monitor sendkey: $character" ;;
        esac
        index=$((index + 1))
    done
}

edit_live_kernel_arguments() {
    local count=0
    sleep "$BOOT_MENU_DELAY_SECS"
    hmp_sendkey e
    sleep 1
    while ((count < GRUB_KERNEL_LINE_DOWNS)); do
        hmp_sendkey down
        count=$((count + 1))
    done
    hmp_sendkey end
    hmp_sendkey spc
    hmp_send_text "$LIVE_KARGS"
    hmp_sendkey ctrl-x
}

wait_for_qemu_with_timeout() {
    local timeout=$1 elapsed=0 status
    while kill -0 "$QEMU_PID" >/dev/null 2>&1; do
        if ((elapsed >= timeout)); then
            kill "$QEMU_PID" >/dev/null 2>&1 || true
            wait "$QEMU_PID" >/dev/null 2>&1 || true
            QEMU_PID=
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if wait "$QEMU_PID"; then
        status=0
    else
        status=$?
    fi
    QEMU_PID=
    return "$status"
}

validate_recovery_output() {
    [[ -f $RECOVERY_KEY_FILE ]] || die "recovery-key output was not created: $RECOVERY_KEY_FILE"
    chmod 0600 "$RECOVERY_KEY_FILE"
    awk '
        NF != 2 { exit 1 }
        $1 !~ /^[0-9a-fA-F-]{36}$/ { exit 1 }
        $2 !~ /^[bcdefghijklnrtuv]{8}(-[bcdefghijklnrtuv]{8}){7}$/ { exit 1 }
        { count++ }
        END { exit count == 2 ? 0 : 1 }
    ' "$RECOVERY_KEY_FILE" || die "recovery-key output is malformed: $RECOVERY_KEY_FILE"
}

run_install() {
    local qemu_status
    create_installer_config
    create_live_wrapper
    create_live_ignition
    start_swtpm
    start_qemu_install
    edit_live_kernel_arguments

    if wait_for_qemu_with_timeout "$INSTALL_TIMEOUT_SECS"; then
        qemu_status=0
    else
        qemu_status=$?
    fi
    stop_swtpm

    if [[ $qemu_status -eq 124 ]]; then
        die "installation timed out after $INSTALL_TIMEOUT_SECS seconds; see $INSTALL_SERIAL_LOG"
    fi
    [[ $qemu_status -eq 0 ]] || die "QEMU exited with status $qemu_status; see $INSTALL_SERIAL_LOG"
    grep -q 'TEST_INSTALL_QEMU_BOOTC_RESULT=0' "$INSTALL_SERIAL_LOG" ||
        die "guest installer did not report success; see $INSTALL_SERIAL_LOG"
    validate_recovery_output
    log "Installation completed successfully"
    log "Recovery keys: $RECOVERY_KEY_FILE"
}

run_boot() {
    start_swtpm
    start_qemu_boot
    log "Installed VM is running; serial output is displayed and logged to $BOOT_SERIAL_LOG"
    local status
    if wait "$QEMU_PID"; then
        status=0
    else
        status=$?
    fi
    QEMU_PID=
    stop_swtpm
    return "$status"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $QEMU_PID ]]; then
        kill "$QEMU_PID" >/dev/null 2>&1
        wait "$QEMU_PID" >/dev/null 2>&1
    fi
    stop_swtpm
    [[ -z $DOWNLOAD_TMP ]] || rm -f -- "$DOWNLOAD_TMP"
    rm -f -- "${MONITOR_SOCKET:-}" "${TPM_SOCKET:-}"
    exit "$status"
}

main() {
    parse_options "$@"
    validate_configuration
    initialize_paths
    require_host_commands
    resolve_firmware
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    case "$RUN_MODE" in
        install)
            reset_install_state
            resolve_fcos_iso
            run_install
            ;;
        boot)
            validate_boot_state
            run_boot
            ;;
        all)
            reset_install_state
            resolve_fcos_iso
            run_install
            validate_boot_state
            run_boot
            ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
