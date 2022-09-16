#!/bin/bash
set -eu -o pipefail
#
# Setup build-chroot's physical and virtual storage
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTDEV=""
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
DEFGEOMARR=(
      /:rootVol:4
      swap:swapVol:2
      /home:homeVol:1
      /var:varVol:2
      /var/tmp:varTmpVol:2
      /var/log:logVol:2
      /var/log/audit:auditVol:100%FREE
   )
DEFGEOMSTR="${DEFGEOMSTR:-$( IFS=$',' ; echo "${DEFGEOMARR[*]}" )}"
FSTYPE="${DEFFSTYPE:-xfs}"
GEOMETRYSTRING="${DEFGEOMSTR}"
SAVIFS="${IFS}"
read -ra VALIDFSTYPES <<< "$( awk '!/^nodev/{ print $1}' /proc/filesystems | tr '\n' ' ' )"


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
   local PART
   SCRIPTEXIT="${1:-1}"

   (
      echo "Usage: ${0} [GNU long option] [option] ..."
      echo "  Options:"
      printf '\t%-4s%s\n' '-d' 'Device to contain the OS partition(s) (e.g., "/dev/xvdf")'
      printf '\t%-4s%s\n' '-f' 'Filesystem-type used chroot-dev device(s) (default: "xfs")'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-m' 'Where to mount chroot-dev (default: "/mnt/ec2-root")'
      printf '\t%-4s%s\n' '-p' 'Comma-delimited string of colon-delimited partition-specs'
      printf '\t%-6s%s\n' '' 'Default layout:'
      for PART in "${DEFGEOMARR[@]}"
      do
         printf '\t%-8s%s\n' '' "${PART}"
      done
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--disk' 'See "-d" short-option'
      printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
      printf '\t%-20s%s\n' '--no-lvm' 'LVM2 objects not used'
      printf '\t%-20s%s\n' '--partition-string' 'See "-p" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Try to ensure good chroot mount-point exists
function ValidateTgtMnt {
   # Ensure chroot mount-point exists
   if [[ -d ${CHROOTMNT} ]]
   then
      if [[ $( mountpoint -q "${CHROOTMNT}" )$? -eq 0 ]]
      then
         err_exit "Selected mount-point [${CHROOTMNT}] already in use. Aborting."
      else
         err_exit "Requested mount-point available for use. Proceeding..." NONE
      fi
   elif [[ -e ${CHROOTMNT} ]] && [[ ! -d ${CHROOTMNT} ]]
   then
      err_exit "Selected mount-point [${CHROOTMNT}] is not correct type. Aborting"
   else
      err_exit "Requested mount-point [${CHROOTMNT}] not found. Creating... " NONE
      install -Ddm 000755 "${CHROOTMNT}" || \
         err_exit "Failed to create mount-point"
      err_exit "Succeeded creating mount-point [${CHROOTMNT}]" NONE
   fi
}

# Mount VG elements
function DoLvmMounts {
   local ELEM
   local MOUNTPT
   local PARTITIONARRAY
   local PARTITIONSTR
   local -A MOUNTINFO

   PARTITIONSTR="${GEOMETRYSTRING}"

   # Convert ${PARTITIONSTR} to iterable partition-info array
   IFS=',' read -ra PARTITIONARRAY <<< "${PARTITIONSTR}"
   IFS="${SAVIFS}"

   # Create associative-array with mountpoints as keys
   for ELEM in "${PARTITIONARRAY[@]}"
   do
      MOUNTINFO[${ELEM//:*/}]=${ELEM#*:}
   done

   # Ensure all LVM volumes are active
   vgchange -a y "${VGNAME}" || err_exit "Failed to activate LVM"

   # Mount volumes
   for MOUNTPT in $( echo "${!MOUNTINFO[*]}" | tr " " "\n" | sort )
   do

      # Ensure mountpoint exists
      if [[ ! -d ${CHROOTMNT}/${MOUNTPT} ]]
      then
          install -dDm 000755 "${CHROOTMNT}/${MOUNTPT}"
      fi

      # Mount the filesystem
      if [[ ${MOUNTPT} == /* ]]
      then
         err_exit "Mounting '${CHROOTMNT}${MOUNTPT}'..." NONE
         mount -t "${FSTYPE}" "/dev/${VGNAME}/${MOUNTINFO[${MOUNTPT}]//:*/}" \
           "${CHROOTMNT}${MOUNTPT}" || \
             err_exit "Unable to mount /dev/${VGNAME}/${MOUNTINFO[${MOUNTPT}]//:*/}"
      else
         err_exit "Skipping '${MOUNTPT}'..." NONE
      fi
   done

}

# Create block/character-special files
function PrepSpecialDevs {

   local    BINDDEV
   local -a CHARDEVS
   local    DEVICE
   local    DEVMAJ
   local    DEVMIN
   local    DEVPRM
   local    DEVOWN

   CHARDEVS=(
         /dev/null:1:3:000666
         /dev/zero:1:5:000666
         /dev/random:1:8:000666
         /dev/urandom:1:9:000666
         /dev/tty:5:0:000666:tty
         /dev/console:5:1:000600
         /dev/ptmx:5:2:000666:tty
      )
   # Prep for loopback mounts
   mkdir -p "${CHROOTMNT}"/{proc,sys,dev/{pts,shm}}

   # Create character-special files
   for DEVSTR in "${CHARDEVS[@]}"
   do
      DEVICE=$( cut -d: -f 1 <<< "${DEVSTR}" )
      DEVMAJ=$( cut -d: -f 2 <<< "${DEVSTR}" )
      DEVMIN=$( cut -d: -f 3 <<< "${DEVSTR}" )
      DEVPRM=$( cut -d: -f 4 <<< "${DEVSTR}" )
      DEVOWN=$( cut -d: -f 5 <<< "${DEVSTR}" )

      # Create any missing device-nodes as needed
      if [[ -e ${CHROOTMNT}${DEVICE} ]]
      then
         err_exit "${CHROOTMNT}${DEVICE} exists" NONE
      else
         err_exit "Making ${CHROOTMNT}${DEVICE}... " NONE
         mknod -m "${DEVPRM}" "${CHROOTMNT}${DEVICE}" c "${DEVMAJ}" "${DEVMIN}" || \
           err_exit "Failed making ${CHROOTMNT}${DEVICE}"

         # Set an alternate group-owner where appropriate
         if [[ ${DEVOWN:-} != '' ]]
         then
            err_exit "Setting ownership on ${CHROOTMNT}${DEVICE}..." NONE
            chown root:"${DEVOWN}" "${CHROOTMNT}${DEVICE}" || \
              err_exit "Failed setting ownership on ${CHROOTMNT}${DEVICE}..."
         fi
      fi
   done

   # Bind-mount pseudo-filesystems
   grep -v "${CHROOTMNT}" /proc/mounts | \
      sed '{
         /^none/d
         /\/tmp/d
         /rootfs/d
         /dev\/sd/d
         /dev\/xvd/d
         /dev\/nvme/d
         /\/user\//d
         /\/mapper\//d
         /^cgroup/d
      }' | awk '{ print $2 }' | sort -u | while read -r BINDDEV
   do
      # Create mountpoints in chroot-env
      if [[ ! -d ${CHROOTMNT}${BINDDEV} ]]
      then
         err_exit "Creating mountpoint: ${CHROOTMNT}${BINDDEV}" NONE
         install -Ddm 000755 "${CHROOTMNT}${BINDDEV}" || \
           err_exit "Failed creating mountpoint: ${CHROOTMNT}${BINDDEV}"
      fi

      err_exit "Mounting ${CHROOTMNT}${BINDDEV}..." NONE
      mount -o bind "${BINDDEV}" "${CHROOTMNT}${BINDDEV}" || \
        err_exit "Failed mounting ${CHROOTMNT}${BINDDEV}"
   done

}



######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o d:f:hm:p: \
   --long disk:,fstype:,help,mountpoint:,no-lvm,partition-string: \
   -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -d|--disk)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  CHROOTDEV="${2}"
                  shift 2;
                  ;;
            esac
            ;;
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
      --no-lvm)
            NOLVM="true"
            shift 1;
            ;;
      -p|--partition-string)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  GEOMETRYSTRING=${2}
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

# *MUST* supply a disk-device
if [[ -z ${CHROOTDEV:-} ]]
then
   err_exit "No block-device specified. Aborting"
elif [[ ! -b ${CHROOTDEV} ]]
then
   err_exit "No such block-device [${CHROOTDEV}]. Aborting"
else
   if [[ ${CHROOTDEV} =~ /dev/nvme ]]
   then
      PARTPRE="p"
   else
      PARTPRE=""
   fi
fi

# Ensure build-target mount-hierarchy is available
ValidateTgtMnt

## Mount partition(s) from second slice
# Locate LVM2 volume-group name
read -r VGNAME <<< "$( pvs --noheading -o vg_name "${CHROOTDEV}${PARTPRE}2" )"

# Do partition-mount if 'no-lvm' explicitly requested
if [[ ${NOLVM:-} == "true" ]]
then
   mount -t "${FSTYPE}" "${CHROOTDEV}${PARTPRE}2" "${CHROOTMNT}"
# Bail if not able to find a LVM2 vg-name
elif [[ -z ${VGNAME:-} ]]
then
   err_exit "No LVM2 volume group found on ${CHROOTDEV}${PARTPRE}2 and" NONE
   err_exit "The '--no-lvm' option not set. Aborting"
# Attempt mount of LVM2 volumes
else
   DoLvmMounts
fi

# Make block/character-special files
PrepSpecialDevs

