#!/bin/bash
set -eu -o pipefail
#
# Install primary OS packages into chroot-env
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
MAINTUSR=${MAINTUSR:-"maintuser"}
TARGTZ="${TARGTZ:-UTC}"

# Make interactive-execution more-verbose unless explicitly told not to
if [[ $( tty -s ) -eq 0 ]] && [[ ${DEBUG} == "UNDEF" ]]
then
   DEBUG="true"
fi


# Error handler function
function err_exit {
   local ERRSTR
   local ISNUM
   local SCRIPTEXIT

   ERRSTR="${1}"
   ISNUM='^[0-9]+$'
   SCRIPTEXIT="${2:-1}"

   if [[ ${DEBUG} == true ]]
   then
      # Our output channels
      logger -i -t "${PROGNAME}" -p kern.crit -s -- "${ERRSTR}"
   else
      logger -i -t "${PROGNAME}" -p kern.crit -- "${ERRSTR}"
   fi

   # Only exit if requested exit is numerical
   if [[ ${SCRIPTEXIT} =~ ${ISNUM} ]]
   then
      exit "${SCRIPTEXIT}"
   fi
}

# Print out a basic usage message
function UsageMsg {
   local SCRIPTEXIT
   SCRIPTEXIT="${1:-1}"

   (
      echo "Usage: ${0} [GNU long option] [option] ..."
      echo "  Options:"
      printf '\t%-4s%s\n' '-f' 'Filesystem-type of chroo-devs (e.g., "xfs")'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-m' 'Where chroot-dev is mounted (default: "/mnt/ec2-root")'
      printf '\t%-4s%s\n' '-z' 'Initial timezone of build-target (default: "UTC")'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
      printf '\t%-20s%s\n' '--no-tmpfs' 'Disable /tmp as tmpfs behavior'
      printf '\t%-20s%s\n' '--timezone' 'See "-z" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Clean yum/DNF history
function CleanHistory {
   err_exit "Executing yum clean..." NONE
   chroot "${CHROOTMNT}" yum clean --enablerepo=* -y packages || \
     err_exit "Failed executing yum clean"

   err_exit "Nuking DNF history DBs..." NONE
   chroot "${CHROOTMNT}" rm -rf /var/lib/dnf/history.* || \
     err_exit "Failed to nuke DNF history DBs"

}

# Set up fstab
function CreateFstab {
   err_exit "Setting up /etc/fstab in chroot-dev..." NONE
   grep "${CHROOTMNT}" /proc/mounts | \
      grep -w "${FSTYPE}" | \
      sed "s/${FSTYPE}.*/${FSTYPE}\tdefaults,rw\t0 0/" \
         >> "${CHROOTMNT}/etc/fstab" || \
        err_exit "Failed setting up /etc/fstab"

   # Set an SELinux label
   if [[ -d ${CHROOTMNT}/sys/fs/selinux ]]
   then
      err_exit "Applying SELinux label to fstab..." NONE
      chcon --reference /etc/fstab "${CHROOTMNT}/etc/fstab" || \
        err_exit "Failed applying SELinux label"
   fi

}

# Configure cloud-init
function ConfigureCloudInit {
   local CLOUDCFG
   local CLINITUSR

   CLOUDCFG="${CHROOTMNT}/etc/cloud/cloud.cfg"
   CLINITUSR=$( grep -E "name: (maintuser|centos|ec2-user|cloud-user)" \
            "${CLOUDCFG}" | awk '{print $2}')

   # Reset key parms in standard cloud.cfg file
   if [ "${CLINITUSR}" = "" ]
   then
      err_exit "Astandard cloud-init file: can't reset default-user config"
   else
      # Ensure passwords *can* be used with SSH
      err_exit "Allow password logins to SSH..." NONE
      sed -i -e '/^ssh_pwauth/s/0$/1/' "${CLOUDCFG}" || \
        err_exit "Failed allowing password logins"

      # Delete current "system_info:" block
      err_exit "Nuking standard system_info block..." NONE
      sed -i '/^system_info/,/^  ssh_svcname/d' "${CLOUDCFG}" || \
        err_exit "Failed to nuke standard system_info block"

      # Replace deleted "system_info:" block
      (
         printf "system_info:\n"
         printf "  default_user:\n"
         printf "    name: '%s'\n" "${MAINTUSR}"
         printf "    lock_passwd: true\n"
         printf "    gecos: Local Maintenance User\n"
         printf "    groups: [wheel, adm]\n"
         printf "    sudo: [ 'ALL=(root) NOPASSWD:ALL' ]\n"
         printf "    shell: /bin/bash\n"
         printf "    selinux_user: unconfined_u\n"
         printf "  distro: rhel\n"
         printf "  paths:\n"
         printf "    cloud_dir: /var/lib/cloud\n"
         printf "    templates_dir: /etc/cloud/templates\n"
         printf "  ssh_svcname: sshd\n"
      ) >> "${CLOUDCFG}"

      # Update NS-Switch map-file for SEL-enabled environment
      err_exit "Enabling SEL lookups by nsswitch..." NONE
      printf "%-12s %s\n" sudoers: files >> "${CHROOTMNT}/etc/nsswitch.conf" || \
        err_exit "Failed enabling SEL lookups by nsswitch"
   fi

}

# Set up logging
function ConfigureLogging {
   local LOGFILE

   # Null out log files
   find "${CHROOTMNT}/var/log" -type f | while read -r LOGFILE
   do
      err_exit "Nulling ${LOGFILE}..." NONE
      cat /dev/null > "${LOGFILE}" || \
        err_exit "Faile to null ${LOGFILE}"
   done

   # Persistent journald logs
   err_exit "Persisting journald logs..." NONE
   echo 'Storage=persistent' >> "${CHROOTMNT}/etc/systemd/journald.conf" || \
     err_exit "Failed persisting journald logs"

   # Ensure /var/log/journal always exists
   err_exit "Creating journald logging-location..." NONE
   install -d -m 0755 "${CHROOTMNT}/var/log/journal" || \
     err_exit "Failed to create journald logging-location"

   err_exit "Ensuring journald logfile storage always exists..." NONE
   chroot "${CHROOTMNT}" systemd-tmpfiles --create --prefix /var/log/journal || \
     err_exit "Failed configuring systemd-tmpfiles"

}

# Configure Networking
function ConfigureNetworking {

   # Set up ifcfg-eth0 file
   err_exit "Setting up ifcfg-eth0 file..." NONE
   (
      printf 'DEVICE="eth0"\n'
      printf 'BOOTPROTO="dhcp"\n'
      printf 'ONBOOT="yes"\n'
      printf 'TYPE="Ethernet"\n'
      printf 'USERCTL="yes"\n'
      printf 'PEERDNS="yes"\n'
      printf 'IPV6INIT="no"\n'
      printf 'PERSISTENT_DHCLIENT="1"\n'
   ) > "${CHROOTMNT}/etc/sysconfig/network-scripts/ifcfg-eth0" || \
     err_exit "Failed setting up file"

   # Set up sysconfig/network file
   err_exit "Setting up network file..." NONE
   (
      printf 'NETWORKING="yes"\n'
      printf 'NETWORKING_IPV6="no"\n'
      printf 'NOZEROCONF="yes"\n'
      printf 'HOSTNAME="localhost.localdomain"\n'
   ) > "${CHROOTMNT}/etc/sysconfig/network" || \
     err_exit "Failed setting up file"

   # Ensure NetworkManager starts
   chroot "${CHROOTMNT}" systemctl enable NetworkManager

}

# Firewalld config
function FirewalldSetup {
   err_exit "Setting up baseline firewall rules..." NONE
   chroot "${CHROOTMNT}" /bin/bash -c "(
      firewall-offline-cmd --direct --add-rule ipv4 filter INPUT_direct 10 \
         -m state --state RELATED,ESTABLISHED -m comment \
         --comment 'Allow related and established connections' -j ACCEPT
      firewall-offline-cmd --direct --add-rule ipv4 filter INPUT_direct 20 \
         -i lo -j ACCEPT
      firewall-offline-cmd --direct --add-rule ipv4 filter INPUT_direct 30 \
         -d 127.0.0.0/8 '!' -i lo -j DROP
      firewall-offline-cmd --direct --add-rule ipv4 filter INPUT_direct 50 \
         -p tcp -m tcp --dport 22 -j ACCEPT
      firewall-offline-cmd --set-default-zone=drop
   )" || \
   err_exit "Failed etting up baseline firewall rules"
}

# Set up grub on chroot-dev
function GrubSetup {
   local CHROOTKRN
   local GRUBCMDLINE
   local ROOTTOK
   local VGCHECK

   # Check what kernel is in the chroot-dev
   CHROOTKRN=$(
         chroot "$CHROOT" rpm --qf '%{version}-%{release}.%{arch}\n' -q kernel
      )

   # See if chroot-dev is LVM2'ed
   VGCHECK="$( grep \ "${CHROOTMNT}"\  /proc/mounts | \
         awk '/^\/dev\/mapper/{ print $1 }'
      )"

   # Determine our "root=" token
   if [[ ${VGCHECK:-} == '' ]]
   then
      err_exit "Bare partitioning not yet supported"
   else
      ROOTTOK="root=${VGCHECK}"
   fi

   # Assemble string for GRUB_CMDLINE_LINUX value
   GRUBCMDLINE="${ROOTTOK} "
   GRUBCMDLINE+="crashkernel=auto "
   GRUBCMDLINE+="vconsole.keymap=us "
   GRUBCMDLINE+="vconsole.font=latarcyrheb-sun16 "
   GRUBCMDLINE+="console=tty0 "
   GRUBCMDLINE+="console=ttyS0,115200n8 "
   GRUBCMDLINE+="net.ifnames=0 "
   GRUBCMDLINE+="fips=0"

   # Write default/grub contents
   err_exit "Writing default/grub file..." NONE
   (
      printf 'GRUB_TIMEOUT=0'
      printf 'GRUB_DISTRIBUTOR="CentOS Linux"'
      printf 'GRUB_DEFAULT=saved'
      printf 'GRUB_DISABLE_SUBMENU=true'
      printf 'GRUB_TERMINAL="serial console"'
      printf 'GRUB_SERIAL_COMMAND="serial --speed=115200"'
      printf 'GRUB_CMDLINE_LINUX="%s"' "${GRUBCMDLINE}"
      printf 'GRUB_DISABLE_RECOVERY=true'
      printf 'GRUB_DISABLE_OS_PROBER=true'
      printf 'GRUB_ENABLE_BLSCFG=true'
   ) > "${CHROOTMNT}/etc/default/grub" || \
     err_exit "Failed writing default/grub file"

   # Install GRUB2 bootloader
   chroot "${CHROOT}" /bin/bash -c "/sbin/grub2-install ${CHROOTDEV}"

   # Install GRUB config-file
   err_exit "Installing GRUB config-file..." NONE
   chroot "${CHROOT}" /bin/bash -c "/sbin/grub2-mkconfig \
      > /boot/grub2/grub.cfg" || \
     err_exit "Failed to install GRUB config-file"

   # Make intramfs in chroot-dev
   err_exit "Installing initramfs..." NONE
   chroot "${CHROOT}" dracut -fv "/boot/initramfs-${CHROOTKRN}.img" \
      "${CHROOTKRN}" || \
     err_exit "Failed installing initramfs"

}

# Configure SELinux
function SELsetup {
   if [[ -d ${CHROOTMNT}/sys/fs/selinux ]]
   then
      err_exit "Setting up SELinux configuration..." NONE
      chroot "${CHROOTMNT}" /bin/sh -c "
         (
            rpm -q --scripts selinux-policy-targeted | \
            sed -e '1,/^postinstall scriptlet/d' | \
            sed -e '1i #!/bin/sh'
         ) > /tmp/selinuxconfig.sh ; \
         bash -x /tmp/selinuxconfig.sh 1" || \
      err_exit "Failed cofiguring SELinux"

      err_exit "Running fixfiles in chroot..." NONE
      chroot "${CHROOTMNT}" /sbin/fixfiles -f relabel || \
        err_exit "Errors running fixfiles"
   else
      err_exit "SELinux not available" NONE
   fi

}

# Timezone setup
function TimeSetup {

   # If requested TZ exists, set it
   if [[ -e ${CHROOTMNT}/usr/share/zoneinfo/${TARGTZ} ]]
   then
      err_exit "Setting default TZ to ${TARGTZ}..." NONE
      rm -f "${CHROOTMNT}/etc/localtime" || \
         err_exit "Failed to clear current TZ default"
      chroot "${CHROOTMNT}" ln -s "/usr/share/zoneinfo/${TARGTZ}" \
         /etc/localtime || \
         err_exit "Failed setting ${TARGTZ}"
   else
      true
   fi

}

# Make /tmp a tmpfs
function SetupTmpfs {
   if [[ ${NOTMPFS:-} != "true" ]]
   then
      err_exit "Unmasking tmp.mount unit..." NONE
      chroot "${CHROOTMNT}" /bin/systemctl unmask tmp.mount || \
        err_exit "Failed unmasking tmp.mount unit"

      err_exit "Enabling tmp.mount unit..." NONE
      chroot "${CHROOTMNT}" /bin/systemctl enable tmp.mount || \
        err_exit "Failed enabling tmp.mount unit"

   fi
}

######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o f:hm:z: \
   --long fstype:,help,mountpoint:,no-tmpfs,timezone \
   -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -f|--fstype)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  FSTYPE="${2}"
                  if [[ $( grep -qw "${FSTYPE}" <<< "${VALIDFSTYPES[*]}" ) -ne 0 ]]
                  then
                     err_exit "Invalid fstype [${FSTYPE}] requested"
                  fi
                  shift 2;
                  ;;
            esac
            ;;
      --no-tmpfs)
            NOTMPFS=true
            ;;
      -h|--help)
            UsageMsg 0
            ;;
      -m|--mountpoint)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  CHROOTMNT=${2}
                  shift 2;
                  ;;
            esac
            ;;
      -z|--timezone)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  TARGTZ=${2}
                  shift 2;
                  ;;
            esac
            ;;
      --)
         shift
         break
         ;;
      *)
         err_exit "Internal error!"
         exit 1
         ;;
   esac
done

###############
# Call to arms!

# Create /etc/fstab in chroot-dev
CreateFstab

# Set /tmp as a tmpfs
SetupTmpfs

# Configure logging
ConfigureLogging

# Configure networking
ConfigureNetworking

# Set up firewalld
FirewalldSetup

# Configure time services
TimeSetup

# Configure cloud-init
ConfigureCloudInit

# Do GRUB2 setup tasks
GrubSetup

# Clean up yum/dnf history
CleanHistory

# Apply SELinux settings
SELsetup

