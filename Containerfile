FROM quay.io/fedora/fedora:44

COPY bootc-base-dirs.conf /usr/lib/tmpfiles.d/bootc-base-dirs.conf
COPY prepare-root.conf /usr/lib/ostree/prepare-root.conf
COPY 30-custom-bootc-composefs-build.conf /usr/lib/dracut/dracut.conf.d/30-custom-bootc-composefs-build.conf

RUN dnf install -y --setopt=install_weak_deps=false \
    bootc \
    bootupd \
    container-selinux \
    coreutils \
    dnf \
    dosfstools \
    e2fsprogs \
    efibootmgr \
    fedora-repos-archive \
    grub2-efi-aa64 \
    shim-aa64 \
    kernel \
    nss-altfiles \
    ostree \
    selinux-policy-targeted \
    shim \
    systemd \
    systemd-boot-unsigned \
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

RUN mkdir /var/tmp && export DRACUT_NO_XATTR=1 && \
    dracut --force --verbose "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img" && \
    rm -rf /var/tmp

RUN bootupctl backend generate-update-metadata

RUN useradd -U -c 'delete me' \
            -G wheel \
            -d /var/home/default \
            -p '$y$j9T$kq/3XQD3zBDpUAOaxEZMj0$dbUPks0Mk8u0vh/XnAoFgPkffy7kx.Fb9ETyRJo6FP2' \
            default

RUN bootc container lint

LABEL containers.bootc=1
LABEL ostree.bootable=1
