#!/bin/bash
set -eu -o pipefail
#
# Script to automate basic setup of CHROOT device
#
#################################################################
PROGNAME=$(basename "$0")
BOOTDEVSZ="${BOOTDEVSZ:-500m}"
BOOTLABEL="#{BOOTLABEL:-/boot}"
CHROOTDEV="${CHROOTDEV:-UNDEF}"
DEBUG="${DEBUG:-UNDEF}"
FSTYPE="${FSTYPE:-xfs}"

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
      printf '\t%-4s%s\n' '-B' 'Boot-partition size (default: 500MiB)'
      printf '\t%-4s%s\n' '-b' 'FS-label applied to boot-partition (default: /boot)'
      printf '\t%-4s%s\n' '-d' 'Base dev-node used for build-device'
      printf '\t%-4s%s\n' '-f' 'Filesystem-type used for root filesystems (default: xfs)'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-p' 'Comma-delimited string of colon-delimited partition-specs'
      printf '\t%-6s%s\n' '' 'Default layout:'
      printf '\t%-8s%s\n' '' '/:rootVol:4'
      printf '\t%-8s%s\n' '' 'swap:swapVol:2'
      printf '\t%-8s%s\n' '' '/home:homeVol:1'
      printf '\t%-8s%s\n' '' '/var:varVol:2'
      printf '\t%-8s%s\n' '' '/var/tmp:varTmpVol:2'
      printf '\t%-8s%s\n' '' '/var/log:logVol:2'
      printf '\t%-8s%s\n' '' '/var/log/audit:auditVol:100%FREE'
      printf '\t%-4s%s\n' '-r' 'Label to apply to root-partition if not using LVM (default: root_disk)'
      printf '\t%-4s%s\n' '-v' 'Name assigned to root volume-group (default: VolGroup00)'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--bootlabel' 'See "-b" short-option'
      printf '\t%-20s%s\n' '--boot-size' 'See "-B" short-option'
      printf '\t%-20s%s\n' '--disk' 'See "-d" short-option'
      printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--partition-string' 'See "-p" short-option'
      printf '\t%-20s%s\n' '--rootlabel' 'See "-r" short-option'
      printf '\t%-20s%s\n' '--vgname' 'See "-v" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Partition as LVM
function CarveLVM {
   local ITER
   local MOUNTPT
   local PARTITIONARRAY
   local PARTITIONSTR
   local VOLFLAG
   local VOLNAME
   local VOLSIZE

   # Whether to use flag-passed partition-string or default values
   if [ -z ${GEOMETRYSTRING+x} ]
   then
       # This is fugly but might(??) be easier for others to follow/update
       PARTITIONSTR="/:rootVol:4"
       PARTITIONSTR+=",swap:swapVol:2"
       PARTITIONSTR+=",/home:homeVol:1"
       PARTITIONSTR+=",/var:varVol:2"
       PARTITIONSTR+=",/var/tmp:varTmpVol:2"
       PARTITIONSTR+=",/var/log:logVol:2"
       PARTITIONSTR+=",/var/log/audit:auditVol:100%FREE"
   else
       PARTITIONSTR="${GEOMETRYSTRING}"
   fi

   # Convert ${PARTITIONSTR} to iterable array
   IFS=',' read -r -a PARTITIONARRAY <<< "${PARTITIONSTR}"

   # Clear the MBR and partition table
   err_exit "Clearing existing partition-tables..." NONE
   dd if=/dev/zero of="${CHROOTDEV}" bs=512 count=1000 > /dev/null 2>&1 || \
     err_exit "Failed clearing existing partition-tables"

   # Lay down the base partitions
   err_exit "Laying down new partition-table..." NONE
   parted -s "${CHROOTDEV}" -- mktable gpt \
      mkpart primary "${FSTYPE}" 2048s "${BOOTDEVSZ}" \
      mkpart primary "${FSTYPE}" "${BOOTDEVSZ}" 100% \
      set 1 bios_grub on \
      set 2 lvm || \
         err_exit "Failed laying down new partition-table"


   # Gather info to diagnose seeming /boot race condition
   if [[ $(grep -q "${BOOTLABEL}" /proc/mounts)$? -eq 0 ]]
   then
     tail -n 100 /var/log/messages
     sleep 3
   fi

   # Stop/umount boot device, in case parted/udev/systemd managed to remount it
   # again.
   systemctl stop boot.mount || true

   # Create /boot filesystem
   mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" -L "${BOOTLABEL}" \
     "${CHROOTDEV}${PARTPRE}1" || \
         err_exit "Failure creating filesystem - /boot"


   ## Create LVM objects

   # Let's only attempt this if we're a secondary EBS
   if [[ ${CHROOTDEV} == /dev/xvda ]] || [[ ${CHROOTDEV} == /dev/nvme0n1 ]]
   then
      err_exit "Skipping explicit pvcreate opertion... " NONE
   else
      err_exit "Creating LVM2 PV ${CHROOTDEV}${PARTPRE:-}2..." NONE
      pvcreate "${CHROOTDEV}${PARTPRE:-}2" || \
        err_exit "PV creation failed. Aborting!"
   fi

   # Create root VolumeGroup
   err_exit "Creating LVM2 volume-group ${VGNAME}..." NONE
   vgcreate -y "${VGNAME}" "${CHROOTDEV}${PARTPRE:-}2" || \
     err_exit "VG creation failed. Aborting!"

   # Create LVM2 volume-objects by iterating ${PARTITIONARRAY}
   ITER=0
   while [[ ${ITER} -lt ${#PARTITIONARRAY[*]} ]]
   do
      MOUNTPT="$( cut -d ':' -f 1 <<< "${PARTITIONARRAY[${ITER}]}")"
      VOLNAME="$( cut -d ':' -f 2 <<< "${PARTITIONARRAY[${ITER}]}")"
      VOLSIZE="$( cut -d ':' -f 3 <<< "${PARTITIONARRAY[${ITER}]}")"

      # Create LVs
      if [[ ${VOLSIZE} =~ FREE ]]
      then
         # Make sure 'FREE' is given as last list-element
         if [[ $(( ITER += 1 )) -eq ${#PARTITIONARRAY[*]} ]]
         then
            VOLFLAG="-l"
            VOLSIZE="100%FREE"
         else
            echo "Using 'FREE' before final list-element. Aborting..."
            kill -s TERM " ${TOP_PID}"
         fi
      else
         VOLFLAG="-L"
         VOLSIZE+="g"
      fi
      lvcreate --yes -W y "${VOLFLAG}" "${VOLSIZE}" -n "${VOLNAME}" "${VGNAME}" || \
        err_exit "Failure creating LVM2 volume '${VOLNAME}'"

      # Create FSes on LVs
      if [[ ${MOUNTPT} == swap ]]
      then
         err_exit "Creating swap filesystem..." NONE
         mkswap "/dev/${VGNAME}/${VOLNAME}" || \
           err_exit "Failed creating swap filesystem..."
      else
         err_exit "Creating filesystem for ${MOUNTPT}..." NONE
         mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" "/dev/${VGNAME}/${VOLNAME}" || \
           err_exit "Failure creating filesystem for '${MOUNTPT}'"
      fi

      (( ITER+=1 ))
   done

   if [[ ${FSTYPE} == ext[34] ]]
   then
      if [[ $( e2label "${CHROOTDEV}${PARTPRE}1" ) != "${BOOTLABEL}" ]]
      then
         e2label "${CHROOTDEV}${PARTPRE}1" "${BOOTLABEL}" || \
            err_exit "Failed to apply desired label to ${CHROOTDEV}${PARTPRE}1"
      fi
   elif [[ ${FSTYPE} == xfs ]]
   then
      if [[ $( xfs_admin -l "${CHROOTDEV}${PARTPRE}1"  | sed -e 's/"$//' -e 's/^.*"//' ) != "${BOOTLABEL}" ]]
      then
         xfs_admin -L "${CHROOTDEV}${PARTPRE}1" "${BOOTLABEL}" || \
            err_exit "Failed to apply desired label to ${CHROOTDEV}${PARTPRE}1"
      fi
   else
      err_exit "Unrecognized fstype [${FSTYPE}] specified. Aborting... "
   fi

}

# Partition with no LVM
function CarveBare {
   # Clear the MBR and partition table
   err_exit "Clearing existing partition-tables..." NONE
   dd if=/dev/zero of="${CHROOTDEV}" bs=512 count=1000 > /dev/null 2>&1 || \
     err_exit "Failed clearing existing partition-tables"

   # Lay down the base partitions
   err_exit "Laying down new partition-table..." NONE
   parted -s "${CHROOTDEV}" -- mklabel gpt \
      mkpart primary "${FSTYPE}" 2048s "${BOOTDEVSZ}" \
      mkpart primary "${FSTYPE}" "${BOOTDEVSZ}" 100% \
      set 1 bios_grub on || \
     err_exit "Failed laying down new partition-table"

   # Create FS on partitions
   err_exit "Creating filesystem on ${CHROOTDEV}${PARTPRE:-}1..." NONE
   mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" -L "${BOOTLABEL}" \
      "${CHROOTDEV}${PARTPRE:-}1" || \
     err_exit "Failed creating filesystem"

   err_exit "Creating filesystem on ${CHROOTDEV}${PARTPRE:-}2..." NONE
   mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" -L "${ROOTLABEL}" \
      "${CHROOTDEV}${PARTPRE:-}2" || \
     err_exit "Failed creating filesystem"
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
  -o b:B:d:f:hp:r:v: \
  --long bootlabel:,boot-size:,disk:,fstype:,help,partition-string:,rootlabel:,vgname: \
  -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -B|--boot-size)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  BOOTDEVSZ=${2}
                  shift 2;
                  ;;
            esac
            ;;
      -b|--bootlabel)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  BOOTLABEL=${2}
                  shift 2;
                  ;;
            esac
            ;;
      -d|--disk)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  CHROOTDEV=${2}
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
               ext3|ext4)
                  FSTYPE=${2}
                  MKFSFORCEOPT="-F"
                  shift 2;
                  ;;
               xfs)
                  FSTYPE=${2}
                  MKFSFORCEOPT="-f"
                  shift 2;
                  ;;
               *)
                  err_exit "Error: unrecognized/unsupported FSTYPE. Aborting..."
                  shift 2;
                  exit 1
                  ;;
            esac
            ;;
      -h|--help)
            UsageMsg 0
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
      -r|--rootlabel)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  ROOTLABEL=${2}
                  shift 2;
                  ;;
            esac
            ;;
      -v|--vgname)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
               VGNAME=${2}
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

# Bail if not root
if [[ ${EUID} != 0 ]]
then
   err_exit "Must be root to execute disk-carving actions"
fi

# See if our carve-target is an NVMe
if [[ ${CHROOTDEV} == "UNDEF" ]]
then
   err_exit "Failed to specify partitioning-target. Aborting"
elif [[ ${CHROOTDEV} =~ /dev/nvme ]]
then
   PARTPRE="p"
else
   PARTPRE=""
fi

# Ensure BOOTLABEL has been specified
if [[ -z ${BOOTLABEL+xxx} ]]
then
   LogBrk 1 "Cannot continue without 'bootlabel' being specified. Aborting..."

# Determine how we're formatting the disk
elif [[ -z ${ROOTLABEL+xxx} ]] && [[ -n ${VGNAME+xxx} ]]
then
   CarveLVM
elif [[ -n ${ROOTLABEL+xxx} ]] && [[ -z ${VGNAME+xxx} ]]
then
   CarveBare
elif [[ -z ${ROOTLABEL+xxx} ]] && [[ -z ${VGNAME+xxx} ]]
then
   err_exit "Failed to specifiy a partitioning-method. Aborting"
else
   err_exit "The '-r'/'--rootlabel' and '-v'/'--vgname' flag-options are mutually-exclusive. Exiting." 0
fi
