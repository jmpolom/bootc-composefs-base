#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

prepare_physical_mount_target() {
    local requested_path=$1
    local target_path=$2
    local parent_path=$target_path

    # Check every component before test -d: test -d follows symlinks.  Walking
    # every requested physical ancestor prevents mkdir from following one.
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
