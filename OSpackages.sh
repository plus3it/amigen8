#!/bin/bash
set -eu -o pipefail
#
# Install primary OS packages into chroot-env
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"

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
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-m' 'Where to mount chroot-dev (default: "/mnt/ec2-root")'
      printf '\t%-4s%s\n' '-r' 'Where to mount chroot-dev (default: "/mnt/ec2-root")'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
      printf '\t%-20s%s\n' '--repolist' 'See "-r" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Default yum repository-list for selected OSes
function GetDefaultRepos {
   local -a BASEREPOS

   # Make sure we can use `rpm` command
   if [[ $(rpm -qa --quiet 2> /dev/null)$? -ne 0 ]]
   then
      err_exit "The rpm command not functioning correctly"
   fi

   case $( rpm -qf /etc/os-release --qf '%{name}' ) in
      centos-release)
         BASEREPOS=(
            BaseOS
            AppStream
            extras
         )
         ;;
      redhat-release-server)
         BASEREPOS=(
            rhel-8-appstream-rhui-rpms
            rhel-8-baseos-rhui-rpms
            rhui-client-config-server-8
         )
         echo "Not yet supported. Aborting" >&2
         exit 1
         ;;
      *)
         echo "Unknown OS. Aborting" >&2
         exit 1
         ;;
   esac

   ( IFS=',' ; echo "${BASEREPOS[*]}" )
}

function PrepChroot {
   local -a BASEPKGS

   # Create an array of packages to install
   mapfile -t BASEPKGS < <(
      rpm --qf '%{name}\n' -qf /etc/os-release ; \
      rpm --qf '%{name}\n' -qf  /etc/yum.repos.d/* 2>&1 | grep -v "not owned" | sort -u ; \
      echo yum-utils
   )

   # Ensure DNS lookups work in chroot-dev
   if [[ ! -e ${CHROOTMNT}/etc/resolv.conf ]]
   then
      err_exit "Installing ${CHROOTMNT}/etc/resolv.conf..." NONE
      install -Dm 000644 /etc/resolv.conf "${CHROOTMNT}/etc/resolv.conf"
   fi

   # Ensure etc/rc.d/init.d exists in chroot-dev
   if [[ ! -e ${CHROOTMNT}/etc/rc.d/init.d ]]
   then
      install -dDm 000755 "${CHROOTMNT}/etc/rc.d/init.d"
   fi

   # Ensure etc/init.d exists in chroot-dev
   if [[ ! -e ${CHROOTMNT}/etc/init.d ]]
   then
      ln -t "${CHROOTMNT}/etc" -s ./rc.d/init.d
   fi

   # Clean out stale RPMs
   if [[ $( stat /tmp/*.rpm > /dev/null 2>&1 )$? -eq 0 ]]
   then
      err_exit "Cleaning out stale RPMs..." NONE
      rm -f /tmp/*.rpm || \
        err_exit "Failed cleaning out stale RPMs"
   fi

   # Stage our base RPMs
   yumdownloader --destdir=/tmp "${BASEPKGS[@]}"

   # Initialize RPM db in chroot-dev
   err_exit "Initializing RPM db..." NONE
   rpm --root "${CHROOTMNT}" --initdb || \
     err_exit "Failed initializing RPM db"

   # Install staged RPMs
   err_exit "Installing staged RPMs..." NONE
   rpm --root "${CHROOTMNT}" -ivh --nodeps /tmp/*.rpm || \
     err_exit "Failed installing staged RPMs"

   # Install dependences for base RPMs
   err_exit "Installing base RPM's dependences..." NONE
   yum --disablerepo="*" --enablerepo="${OSREPOS}" \
      --installroot="${CHROOTMNT}" -y reinstall "${BASEPKGS[@]}" || \
     err_exit "Failed installing base RPM's dependences"

   # Ensure yum-utils are installed in chroot-dev
   err_exit "Ensuring yum-utils are installed..." NONE
   yum --disablerepo="*" --enablerepo="${OSREPOS}" \
      --installroot="${CHROOTMNT}" -y install yum-utils || \
     err_exit "Failed installing yum-utils"

}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o hm:r: \
   --long help,mountpoint:,repolist: \
   -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
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
      -r|--repolist)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  OSREPOS=${2}
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

# Repos to activate
if [[ ${OSREPOS:-} == '' ]]
then
   OSREPOS="$( GetDefaultRepos )"
fi

# Install minimum RPM-set into chroot-dev
PrepChroot
