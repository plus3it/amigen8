#!/bin/bash
set -eo pipefail
set -x

EFI_HOME="$( rpm -ql grub2-common | grep '/EFI/' )"
GRUB_HOME=/boot/grub2

# Re-Install RPMs as necessary
if [[ $( rpm --quiet -q grub2-pc )$? -eq 0 ]]
then
  dnf -y reinstall grub2-pc
else
  dnf -y install grub2-pc
fi

# Move "${EFI_HOME}/grub.cfg" as necessary
if [[ -e ${EFI_HOME}/grub.cfg ]]
then
  mv "${EFI_HOME}/grub.cfg" /boot/grub2
fi

# Make our /boot-hosted GRUB2 grub.cfg file
grub2-mkconfig -o /boot/grub2/grub.cfg

# Nuke grubenv file as necessary
if [[ -e /boot/grub2/grubenv ]]
then
  rm -f /boot/grub2/grubenv
fi

# Create fresh grubenv file
grub2-editenv /boot/grub2/grubenv create

# Populate fresh grubenv file:
#   Use `grub2-editenv` command to list parm/vals already stored in the
#   "${EFI_HOME}/grubenv"and dupe them into the BIOS-boot GRUB2 env config
while read -r line
do
  key="$( echo "$line" | cut -f1 -d'=' )"
  value="$( echo "$line" | cut -f2- -d'=' )"
  grub2-editenv /boot/grub2/grubenv set "${key}"="${value}"
done <<< "$( grub2-editenv "${EFI_HOME}/grubenv" list )"

if [[ -e ${EFI_HOME}/grubenv ]]
then
  rm -f "${EFI_HOME}/grubenv"
fi


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
if [[ -e /etc/grub2-efi.cfg ]]
then
  rm -f /etc/grub2-efi.cfg
fi

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
