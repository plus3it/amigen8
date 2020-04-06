#!/bin/bash
set -eu -o pipefail
#
# Setup build-chroot's physical and virtual storage
#
#######################################################################
PROGNAME=$(basename "$0")
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

# Make interactive-execution more-verbose unless explicitly told not to
if [[ $( tty -s ) -eq 0 ]] && [[ ${DEBUG} == "UNDEF" ]]
then
   DEBUG="true"
fi


# Error handler function
function err_exit {
   local ERRSTR
   local SCRIPTEXIT

   ERRSTR="${1}"
   SCRIPTEXIT="${2:-1}"

   if [[ ${DEBUG} == true ]]
   then
      # Our output channels
      logger -i -t "${PROGNAME}" -p kern.crit -s -- "${ERRSTR}"
   else
      logger -i -t "${PROGNAME}" -p kern.crit -- "${ERRSTR}"
   fi

   exit "${SCRIPTEXIT}"
}
# Print out a basic usage message
function UsageMsg {
   local SCRIPTEXIT
   local PART
   SCRIPTEXIT="${1:-1}"

   (
      echo "Usage: ${0} [GNU long option] [option] ..."
      echo "  Options:"
      printf '\t%-4s%s\n' '-d' 'Device contining "/boot" partition'
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



######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
   -o d:hp: \
   --long disk:,help,partition-string: \
   -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

UsageMsg
