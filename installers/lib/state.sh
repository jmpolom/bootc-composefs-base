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
            die "external volume target is a symlink: $requested_path"
        fi
        if [[ -e $parent_path ]]; then
            [[ -d $parent_path ]] || die "external volume target is not a directory: $requested_path"
        fi
        parent_path=${parent_path%/*}
        [[ -n $parent_path ]] || parent_path=/
    done

    [[ -e $target_path ]] && return 0

    mkdir -p -- "$target_path"
    [[ ! -L $target_path && -d $target_path ]] ||
        die "external volume target could not be created as a directory: $requested_path"
}

vol_prepare_targets() {
    local config_root=$1
    local persistent_var=$2
    local record mount_point target_path

    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[phase]:-predeploy} == postdeploy ]] || continue
        mount_point=${volume[mountpoint]}
        target_path=$(mount_target_path "$config_root" "$persistent_var" "$mount_point")
        prepare_mount_target "$mount_point" "$target_path"
    done
}

clear_directory() {
    local directory=$1
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

vol_migrate_mounts() {
    local config_root=$1
    local persistent_var=$2
    local record filesystem options mount_point target_path source staging
    local -a order=()

    mapfile -t order < <(volume_phase_order postdeploy)

    for record in "${order[@]}"; do
        local -n volume=$record
        filesystem=${volume[fs]}; vol_mount_options options "$record"; mount_point=${volume[mountpoint]}
        target_path=$(mount_target_path "$config_root" "$persistent_var" "$mount_point")
        source=${volume[_source]:-}
        [[ -n $source ]] || die "external volume source is unavailable for $mount_point"
        if [[ ${volume[action]} == relation && ${volume[backing]:-} == vol_root ]]; then
            local -n root=vol_root
            local relation_path=$install_root
            if [[ ${volume[subvol]:-} == "${root[subvol]:-}"/* ]]; then
                relation_path=$install_root/${volume[subvol]#"${root[subvol]}"/}
            fi
            [[ $target_path == "$relation_path" ]] && continue
        fi
        staging=$work_root/$record
        mkdir -p "$staging"
        vol_mount_filesystem "$source" "$filesystem" "$options" "$staging"
        cleanup_mounts+=("$staging")

        log "Migrating existing content for $mount_point onto $source"
        if state_path_for_mount "$persistent_var" "$mount_point" >/dev/null; then
            chown root:root "$staging"; chmod 0755 "$staging"
            label_new_state_path "$staging" "$mount_point" "$target_path"
        fi
        cp -a --reflink=auto "$target_path/." "$staging/"
        clear_directory "$target_path"
        umount "$staging"
        unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
        vol_mount_filesystem "$source" "$filesystem" "$options" "$target_path"
        cleanup_mounts+=("$target_path")
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
