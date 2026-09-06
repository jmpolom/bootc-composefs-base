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

move_state_to_subvolume() {
    local name=$1
    local state_path=$2
    local runtime_path=$3
    local old_path="${state_path}.bootc-installer-old"
    local parent_path

    log "Moving $state_path into Btrfs subvolume $name"
    if [[ ! -e $state_path && ! -L $state_path ]]; then
        parent_path=$(dirname -- "$state_path")
        [[ -d $parent_path && ! -L $parent_path ]] ||
            die "state-subvolume parent is not a directory: $parent_path"
        log "Creating empty Btrfs subvolume $name at $state_path"
        btrfs subvolume create "$state_path"
        chown root:root "$state_path"
        chmod 0755 "$state_path"
        label_new_state_path "$state_path" "$runtime_path" "$parent_path"
        return
    fi

    [[ -d $state_path && ! -L $state_path ]] || die "state path is not a directory: $state_path"
    [[ ! -e $old_path ]] || die "temporary migration path already exists: $old_path"
    mv "$state_path" "$old_path"
    btrfs subvolume create "$state_path"
    chown root:root "$state_path"
    chmod 0755 "$state_path"
    label_new_state_path "$state_path" "$runtime_path" "$old_path"
    cp -a --reflink=auto "$old_path/." "$state_path/"
    rm -rf -- "$old_path"
}

configure_state_subvolumes() {
    local persistent_var=$1

    [[ -d $persistent_var ]] || die "bootc did not create persistent var at $persistent_var"
    if [[ $separate_var == true ]]; then
        move_state_to_subvolume var "$persistent_var" /var
    fi
    if [[ $separate_home == true ]]; then
        move_state_to_subvolume home "$persistent_var/home" /var/home
    fi
    if [[ $separate_opt == true ]]; then
        move_state_to_subvolume opt "$persistent_var/opt" /var/opt
    fi
}

state_path_for_mount() {
    local persistent_var=$1
    local mount_point=$2
    local runtime_path
    runtime_path=$(runtime_path_for_mount "$mount_point")

    case "$runtime_path" in
        /var) printf '%s\n' "$persistent_var" ;;
        /var/*) printf '%s/%s\n' "$persistent_var" "${runtime_path#/var/}" ;;
        *) return 1 ;;
    esac
}

clear_directory() {
    local directory=$1
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

configure_extra_mounts() {
    local persistent_var=$1
    local count=${#extra_mount_devices[@]}
    ((count > 0)) || return 0

    local index label filesystem options mount_point runtime_path source staging state_path
    for ((index = 0; index < count; index++)); do
        label=${extra_mount_labels_resolved[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        options=${extra_mount_options[$index]:-defaults}
        mount_point=${extra_mount_points[$index]}
        runtime_path=$(runtime_path_for_mount "$mount_point")
        source=/dev/disk/by-label/$label
        staging=$work_root/extra-$index

        mkdir -p "$staging"
        mount -t "$filesystem" -o "$options" "$source" "$staging"
        cleanup_mounts+=("$staging")

        if state_path=$(state_path_for_mount "$persistent_var" "$mount_point"); then
            log "Moving existing state for $mount_point onto $source"
            mkdir -p "$state_path"
            chown root:root "$staging"
            chmod 0755 "$staging"
            label_new_state_path "$staging" "$runtime_path" "$state_path"
            cp -a --reflink=auto "$state_path/." "$staging/"
            clear_directory "$state_path"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"

            mount -t "$filesystem" -o "$options" "$source" "$state_path"
            cleanup_mounts+=("$state_path")
        else
            log "$mount_point has no pre-existing bootc state path to migrate"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
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
        usermod --root "$config_root" --password "$user_password_hash" "$user_name"
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

relabel_target_paths() {
    local config_root=$1
    local contexts=$config_root/etc/selinux/targeted/contexts/files/file_contexts
    command -v setfiles >/dev/null 2>&1 || return 0
    [[ -r $contexts ]] || return 0

    log "Applying target SELinux labels to mutable state"
    setfiles -F -r "$config_root" "$contexts" "$config_root/etc" ||
        die "failed to label target configuration"
}
