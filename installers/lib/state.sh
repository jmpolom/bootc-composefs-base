#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

label_new_state_path() {
    local state_path=$1
    local runtime_path=$2
    local parent_path=$3
    local context

    if command -v matchpathcon >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
        if context=$(matchpathcon -n "$runtime_path"); then
            if chcon "$context" "$state_path"; then
                return
            fi
            log "SELinux context application was unavailable for $state_path"
        else
            log "SELinux policy lookup was unavailable for $runtime_path"
        fi
    fi

    if command -v chcon >/dev/null 2>&1; then
        chcon --reference="$parent_path" "$state_path" ||
            log "SELinux context copy was unavailable for $state_path"
    fi
}

state_path_for_mount() {
    local persistent_var=$1
    local mount_point=$2

    case "$mount_point" in
        /var) printf '%s\n' "$persistent_var" ;;
        /var/*) printf '%s/%s\n' "$persistent_var" "${mount_point#/var/}" ;;
        *) return 1 ;;
    esac
}

mount_target_path() {
    local config_root=$1
    local persistent_var=$2
    local mount_point=$3
    local state_path

    if state_path=$(state_path_for_mount "$persistent_var" "$mount_point"); then
        printf '%s\n' "$state_path"
    else
        printf '%s%s\n' "$config_root" "$mount_point"
    fi
}

prepare_mount_target() {
    local requested_path=$1
    local target_path=$2
    local parent_path=$target_path

    # Check every component before test -d: test -d follows symlinks.  Walking
    # through all ancestors prevents mkdir or migration from following a
    # symlink, including when the requested descendant already exists.
    while [[ $parent_path != / ]]; do
        if [[ -L $parent_path ]]; then
            die "extra mount target is a symlink: $requested_path"
        fi
        if [[ -e $parent_path ]]; then
            [[ -d $parent_path ]] || die "extra mount target is not a directory: $requested_path"
        fi
        parent_path=${parent_path%/*}
        [[ -n $parent_path ]] || parent_path=/
    done

    [[ -e $target_path ]] && return 0

    mkdir -p -- "$target_path"
    [[ ! -L $target_path && -d $target_path ]] ||
        die "extra mount target could not be created as a directory: $requested_path"
}

root_backed_extra_mount_path() {
    local index=$1
    local subvolume
    subvolume=$(root_backed_extra_mount_subvolume "$index") || return 1
    printf '%s%s\n' "$install_root" "${subvolume#root}"
}

prepare_root_backed_extra_mount() {
    local subvolume=$1
    local subvolume_path=$2
    local parent_path=$subvolume_path
    local old_path

    # The subvolume path is inside the already-mounted root filesystem.  Do
    # not follow symlinks while preparing any missing parent, and do not
    # replace a symlink or non-directory supplied by the image.
    while [[ $parent_path != / ]]; do
        if [[ -L $parent_path ]]; then
            die "root-backed extra subvolume is a symlink: $subvolume"
        fi
        if [[ -e $parent_path ]]; then
            [[ -d $parent_path ]] || die "root-backed extra subvolume is not a directory: $subvolume"
        fi
        parent_path=${parent_path%/*}
        [[ -n $parent_path ]] || parent_path=/
    done

    if btrfs subvolume show "$subvolume_path" >/dev/null 2>&1; then
        return 0
    fi
    [[ ! -L $subvolume_path ]] || die "root-backed extra subvolume is a symlink: $subvolume"

    if [[ -e $subvolume_path ]]; then
        [[ -d $subvolume_path ]] || die "root-backed extra subvolume is not a directory: $subvolume"
        old_path="${subvolume_path}.bootc-installer-old"
        [[ ! -e $old_path && ! -L $old_path ]] ||
            die "temporary migration path already exists: $old_path"
        mv "$subvolume_path" "$old_path"
        btrfs subvolume create "$subvolume_path"
        chown root:root "$subvolume_path"
        chmod 0755 "$subvolume_path"
        cp -a --reflink=auto "$old_path/." "$subvolume_path/"
        rm -rf -- "$old_path"
    else
        mkdir -p -- "$(dirname -- "$subvolume_path")"
        btrfs subvolume create "$subvolume_path"
        chown root:root "$subvolume_path"
        chmod 0755 "$subvolume_path"
    fi
}

prepare_extra_mount_targets() {
    local config_root=$1
    local persistent_var=$2
    local count=${#extra_mount_devices[@]}
    local index mount_point target_path

    for ((index = 0; index < count; index++)); do
        mount_point=${extra_mount_points[$index]}
        target_path=$(mount_target_path "$config_root" "$persistent_var" "$mount_point")
        prepare_mount_target "$mount_point" "$target_path"
    done
}

clear_directory() {
    local directory=$1
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

configure_extra_mounts() {
    local config_root=$1
    local persistent_var=$2
    local count=${#extra_mount_devices[@]}
    ((count > 0)) || return 0

    local index label filesystem options mount_point target_path source staging root_subvolume root_subvolume_path
    for ((index = 0; index < count; index++)); do
        label=${extra_mount_labels_resolved[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        options=${extra_mount_options[$index]:-defaults}
        mount_point=${extra_mount_points[$index]}
        target_path=$(mount_target_path "$config_root" "$persistent_var" "$mount_point")
        source=/dev/disk/by-label/$label
        staging=$work_root/extra-$index

        if root_subvolume=$(root_backed_extra_mount_subvolume "$index"); then
            root_subvolume_path=$(root_backed_extra_mount_path "$index")
            prepare_root_backed_extra_mount "$root_subvolume" "$root_subvolume_path"
            # /var and its descendants already name the selected subvolume in
            # the installed tree.  Leave that mount in place; the boot karg
            # will mount the same root-backed subvolume in the deployed system.
            if [[ $target_path == "$root_subvolume_path" ]]; then
                log "Prepared root-backed Btrfs subvolume $root_subvolume for $mount_point"
                continue
            fi
        fi

        mkdir -p "$staging"
        mount -t "$filesystem" -o "$options" "$source" "$staging"
        cleanup_mounts+=("$staging")

        if state_path_for_mount "$persistent_var" "$mount_point" >/dev/null; then
            log "Moving existing state for $mount_point onto $source"
            chown root:root "$staging"
            chmod 0755 "$staging"
            label_new_state_path "$staging" "$mount_point" "$target_path"
            cp -a --reflink=auto "$target_path/." "$staging/"
            clear_directory "$target_path"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"

            mount -t "$filesystem" -o "$options" "$source" "$target_path"
            cleanup_mounts+=("$target_path")
        else
            log "Migrating existing content for literal target $mount_point onto $source"
            cp -a --reflink=auto "$target_path/." "$staging/"
            clear_directory "$target_path"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"

            mount -t "$filesystem" -o "$options" "$source" "$target_path"
            cleanup_mounts+=("$target_path")
        fi
    done
}

configure_first_user() {
    local config_root=$1
    local persistent_var=$2
    [[ -n ${user_name:-} ]] || return 0

    [[ -f $config_root/etc/passwd ]] || die "target passwd file is missing"
    grep -q '^wheel:' "$config_root/etc/group" || die "target image does not define the wheel group"
    if grep -q "^${user_name}:" "$config_root/etc/passwd"; then
        die "target image already defines user $user_name"
    fi

    log "Creating initial administrative user $user_name"
    local -a useradd_args=(
        --root "$config_root"
        --no-create-home
        --groups wheel
        --shell "$user_shell"
        --comment "$user_gecos"
    )
    if grep -q "^${user_name}:" "$config_root/etc/group"; then
        useradd_args+=(--gid "$user_name")
    else
        useradd_args+=(--user-group)
    fi
    useradd "${useradd_args[@]}" "$user_name"

    if [[ -n ${user_password_hash:-} ]]; then
        apply_user_password_hash "$config_root" "$user_name"
    else
        usermod --root "$config_root" --lock "$user_name"
    fi

    local uid gid
    uid=$(awk -F: -v user="$user_name" '$1 == user { print $3 }' "$config_root/etc/passwd")
    gid=$(awk -F: -v user="$user_name" '$1 == user { print $4 }' "$config_root/etc/passwd")
    [[ -n $uid && -n $gid ]] || die "could not resolve the new user's uid/gid"
    mkdir -p "$persistent_var/home/$user_name"
    chmod 0700 "$persistent_var/home/$user_name"
    chown "$uid:$gid" "$persistent_var/home/$user_name"
}

apply_user_password_hash() {
    local config_root=$1
    local user_name=$2
    local status

    if usermod --root "$config_root" --password "$user_password_hash" "$user_name"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

relabel_target_paths() {
    local config_root=$1
    local contexts=$config_root/etc/selinux/targeted/contexts/files/file_contexts
    command -v setfiles >/dev/null 2>&1 || return 0
    [[ -r $contexts ]] || return 0

    log "Applying target SELinux labels to mutable state"
    setfiles -F -r "$config_root" "$contexts" "$config_root/etc" ||
        die "failed to label target configuration"
}
