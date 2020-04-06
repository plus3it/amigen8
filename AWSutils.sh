#!/bin/bash
set -eu -o pipefail
#
# Install, configure and activate AWS utilities
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
CLIV1SOURCE="${CLIV1SOURCE:-UNDEF}"
CLIV2SOURCE="${CLIV2SOURCE:-UNDEF}"
DEBUG="${DEBUG:-UNDEF}"
UTILSDIR="${UTILSDIR:-UNDEF}"

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
      printf '\t%-4s%s\n' '-C' 'Where to get AWS CLIv2'
      printf '\t%-4s%s\n' '-c' 'Where to get AWS CLIv2'
      printf '\t%-4s%s\n' '-d' 'Directory containing installable utility-RPMs'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-m' 'Where chroot-dev is mounted (default: "/mnt/ec2-root")'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--cli-v1' 'See "-C" short-option'
      printf '\t%-20s%s\n' '--cli-v2' 'See "-c" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
      printf '\t%-20s%s\n' '--utils-dir' 'See "-d" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Install AWS CLI version 1.x
function InstallCLIv1 {
   true
}

# Install AWS CLI version 2.x
function InstallCLIv2 {
   true
}

# Install AWS utils from "directory"
function InstallFromDir {
   true
}

######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o C:c:d:hm:\
   --long cli-v1:,cli-v2:,help,mountpoint:,utils-dir: \
   -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -C|--cli-v1)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  CLIV1SOURCE="${2}"
                  shift 2;
                  ;;
            esac
            ;;
      -c|--cli-v2)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  CLIV2SOURCE="${2}"
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
                  CHROOTMNT="${2}"
                  shift 2;
                  ;;
            esac
            ;;
      -d|--utils-dir)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  UTILSDIR="${2}"
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

