#!/bin/bash
set -euo pipefail

# Re-Install RPMs as necessary
dnf -y reinstall grub2-pc

# Move /boot/efi/EFI/redhat/grub.cfg as necessary
[[ -e /boot/efi/EFI/redhat/grub.cfg ]] && \
  mv /boot/efi/EFI/redhat/grub.cfg /boot/grub2

# Make our /boot-hosted GRUB2 grub.cfg file
grub2-mkconfig -o /boot/grub2/grub.cfg

# Nuke grubenv file as necessary
[[ -e /boot/grub2/grubenv ]] && rm -f /boot/grub2/grubenv

# Create fresh grubenv file
grub2-editenv /boot/grub2/grubenv create

# Populate fresch grubenv file
while read -r line
do
  key="$( echo "$line" | cut -f1 -d'=' )"
  value="$( echo "$line" | cut -f2- -d'=' )"
  grub2-editenv /boot/grub2/grubenv set "${key}"="${value}"
  done <<< "$( grub2-editenv /boot/efi/EFI/redhat/grubenv list )"

[[ -e /boot/efi/EFI/redhat/grubenv ]] && rm -f /boot/efi/EFI/redhat/grubenv


EFI_HOME=/boot/efi/EFI/redhat
GRUB_HOME=/boot/grub2

BOOT_UUID="$( grub2-probe --target=fs_uuid "${GRUB_HOME}" )"
GRUB_DIR="$( grub2-mkrelpath "${GRUB_HOME}" )"

# Ensure EFI grub.cfg is correctly populated
cat << EOF > "${EFI_HOME}/grub.cfg"
connectefi scsi
search --no-floppy --fs-uuid --set=dev ${BOOT_UUID}
set prefix=(\$dev)${GRUB_DIR}
export \$prefix
configfile \$prefix/grub.cfg
EOF

# Clear out stale grub2-efi.cfg file as necessary
[[ -e /etc/grub2-efi.cfg ]] && rm -f /etc/grub2-efi.cfg

# Link the BIOS- and EFI-boot GRUB-config files
ln -s ../boot/grub2/grub.cfg /etc/grub2-efi.cfg

# Calculate the /boot-hosting root-device
GRUB_TARG="$( df -P /boot/grub2 | awk 'NR>=2 { print $1 }' )"

# Trim off partition-info
case "${GRUB_TARG}" in
  /dev/nvme*)
    GRUB_TARG="${GRUB_TARG//p*/}"
    ;;
  /dev/xvd*)
    GRUB_TARG="${GRUB_TARG::-1}"
    ;;
  *)
    echo "Unsupported disk-type. Aborting..."
    exit 1
    ;;
esac

# Install the /boot/grub2/i386-pc content
grub2-install --target i386-pc "${GRUB_TARG}"
