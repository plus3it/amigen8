#!/bin/bash
# set -euo pipefail
#
# Script to clean up all devices mounted under $CHROOT
#
#################################################################
CHROOT="${CHROOT:-/mnt/ec2-root}"
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
      printf '\t%-4s%s\n' '-c' 'Where chroot-dev is set up (default: "/mnt/ec2-root")'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--chroot' 'See "-c" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
   )
   exit "${SCRIPTEXIT}"
}


# Do dismount
function UnmountThem {
   local BLK

   while read -r BLK
   do
      err_exit "Unmounting ${BLK}" NONE
      umount "${BLK}" || \
        err_exit "Failed unmounting ${BLK}"
   done < <( cut -d " " -f 3 <( mount ) | grep "${CHROOT}" | sort -r )
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o c:h\
   --long chroot:,help\
   -n "${PROGNAME}" -- "$@" )

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -c|--chroot)
         case "$2" in
         "")
            LogBrk 1 "Error: option required but not specified"
            shift 2;
            exit 1
         ;;
         *)
            CHROOT="${2}"
            shift 2;
            ;;
         esac
         ;;
      -h|--help)
            UsageMsg 0
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

# Do the work
UnmountThem
