#!/bin/bash
set -eu -o pipefail
#
# Setup build-chroot's physical and virtual storage
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTDEV=""
CHROOTMNT="${CHROOTMNT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
DEFGEOMARR=(
      /:rootVol:4
      swap:swapVol:2
      /home:homeVol:1
      /var:varVol:2
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
      printf '\t%-4s%s\n' '-d' 'Device contining "/boot" partition (e.g., "/dev/xvdf")'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-p' 'Comma-delimited string of colon-delimited partition-specs'
      printf '\t%-6s%s\n' '' 'Default layout:'
      for PART in ${DEFGEOMARR[*]}
      do
         printf '\t%-8s%s\n' '' "${PART}"
      done
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--disk' 'See "-d" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
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
   for ELEM in ${PARTITIONARRAY[*]}
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
         echo "Mounting '${CHROOTMNT}${MOUNTPT}'..."
         mount -t "${FSTYPE}" "/dev/${VGNAME}/${MOUNTINFO[${MOUNTPT}]//:*/}" \
           "${CHROOTMNT}${MOUNTPT}" || \
             err_exit "Unable to mount /dev/${VGNAME}/${MOUNTINFO[${MOUNTPT}]//:*/}"
      else
         echo "Skipping '${MOUNTPT}'..."
      fi
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
                  LogBrk 1 "Error: option required but not specified"
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
                  LogBrk 1 "Error: option required but not specified"
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
                  LogBrk 1"Error: option required but not specified"
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
            ;;
      -p|--partition-string)
            case "$2" in
               "")
                  LogBrk 1"Error: option required but not specified"
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
         LogBrk 1 "Internal error!"
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

# Ensure build-target /boot mountpoint exists
if [[ ! -d ${CHROOTMNT}/boot ]]
then
   install -Ddm 000755 "${CHROOTMNT}/boot" || \
     err_exit "Failed creating ${CHROOTMNT}/boot"
fi

# Mount build-target /boot filesystem
mount -t "${FSTYPE}" "${CHROOTDEV}${PARTPRE}1" "${CHROOTMNT}/boot" || \
  err_exit "Failed mounting ${CHROOTMNT}/boot"
