ARG RELEASE=44
FROM quay.io/fedora/fedora:${RELEASE}

COPY bootc-base-dirs.conf /usr/lib/tmpfiles.d/bootc-base-dirs.conf
COPY prepare-root.conf /usr/lib/ostree/prepare-root.conf
COPY 30-custom-bootc-composefs-build.conf /usr/lib/dracut/dracut.conf.d/30-custom-bootc-composefs-build.conf
COPY 00-bootc-networkd.preset /usr/lib/systemd/system-preset/00-bootc-networkd.preset
COPY 20-bootc-wired.network /usr/lib/systemd/network/20-bootc-wired.network

RUN dnf install -y --setopt=install_weak_deps=false \
    audit \
    bootc \
    bootupd \
    btrfs-progs \
    container-selinux \
    coreutils \
    cryptsetup \
    dbus-broker \
    dnf \
    dosfstools \
    e2fsprogs \
    efibootmgr \
    fedora-repos-archive \
    gdisk \
    grub2-efi \
    iproute \
    kernel \
    nss-altfiles \
    ostree \
    policycoreutils \
    selinux-policy-targeted \
    shim \
    systemd \
    systemd-boot-unsigned \
    systemd-networkd \
    systemd-pam \
    systemd-resolved \
    tpm2-tools \
    xfsprogs

RUN rm -rf /boot /home /mnt /root /usr/local /src /opt /var /usr/lib/sysimage/log && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && \
    ln -sT /var/roothome /root && \
    ln -sT /var/opt /opt && \
    ln -sT /var/mnt /mnt && \
    ln -sT /var/home /home && \
    ln -sT /var/usrlocal /usr/local

RUN ls /usr/lib/tmpfiles.d /usr/lib/ostree /usr/lib/dracut/dracut.conf.d

RUN mkdir -p /var/tmp && export DRACUT_NO_XATTR=1 && \
    test "$(rpm -q kernel-core | wc -l)" -eq 1 && \
    kernel_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)" && \
    test -d "/usr/lib/modules/${kernel_version}" && \
    dracut --force --verbose \
        "/usr/lib/modules/${kernel_version}/initramfs.img" \
        "${kernel_version}" && \
    rm -rf /var/tmp

RUN bootupctl backend generate-update-metadata

RUN useradd -U -c 'delete me' \
            -G wheel \
            -d /var/home/default \
            -p '$y$j9T$kq/3XQD3zBDpUAOaxEZMj0$dbUPks0Mk8u0vh/XnAoFgPkffy7kx.Fb9ETyRJo6FP2' \
            default

COPY installers/ /usr/libexec/bootc-installer/

RUN bootc container lint

LABEL containers.bootc=1
LABEL ostree.bootable=1
