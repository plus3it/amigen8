#!/bin/bash
set -eu -o pipefail
#
# Install primary OS packages into chroot-env
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
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
      chroot "${CHROOTMNT}" ln -s "/usr/share/zoneinfo/${TARGTZ}" | \
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
