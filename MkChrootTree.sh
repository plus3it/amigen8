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
DEFFSTYPE="${DEFFSTYPE:-xfs}"
DEFGEOMARR=(
      /:rootVol:4
      swap:swapVol:2
      /home:homeVol:1
      /var:varVol:2
      /var/log:logVol:2
      /var/log/audit:auditVol:100%FREE
   )
DEFGEOMSTR="${DEFGEOMSTR:-$( IFS=$',' ; echo "${DEFGEOMARR[*]}" )}"
GEOMETRYSTRING=""

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
      if [[ $( mountpoint -q "${CHROOTMNT}" ) -eq 0 ]]
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



######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o d:hm:p: \
   --long disk:,help,mountpoint:,partition-string: \
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
fi

# Use default geometry-string
if [[ ${GEOMETRYSTRING:-} == "" ]]
then
   GEOMETRYSTRING=${DEFGEOMSTR}
fi

# Ensure build-target mount-hierarchy is available
ValidateTgtMnt
