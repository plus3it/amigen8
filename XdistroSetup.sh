#!/bin/bash
set -eu -o pipefail
#
# Script to automate basic preparation of a cross-distro
# bootstrap-builder host for a given alternate-distro
# build-target
#
#################################################################
PROGNAME=$( basename "$0" )
RUNDIR="$( dirname "$0" )"
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
      printf '\t%-4s%s\n' '-d' 'Distro nickname (e.g., "Rocky")'
      printf '\t%-4s%s\n' '-h' 'Print this message'
      printf '\t%-4s%s\n' '-k' 'List of RPM-validation key-files or RPMs'
      printf '\t%-4s%s\n' '-r' 'List of repository-related RPMs'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--distro-name' 'See "-d" short-option'
      printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
      printf '\t%-20s%s\n' '--repo-rpms' 'See "-r" short-option'
      printf '\t%-20s%s\n' '--sign-keys' 'See "-k" short-option'
   )
   exit "${SCRIPTEXIT}"
}

# Install the alt-distro's GPG key(s)
function InstallGpgKeys {
   local ITEM

   for ITEM in "${PKGSIGNKEYS[@]}"
   do
      if [[ ${ITEM} == "" ]]
      then
         break
      elif [[ ${ITEM} == *.rpm ]]
      then
         echo yum install -y "${ITEM}"
      else
         printf "Installing %s to /etc/pki/rpm-gpg... " \
           "${ITEM}"
         cd /etc/pki/rpm-gpg || err_exit "Could not chdir"
         curl -sOkL "${ITEM}" || err_exit "Download failed"
         echo "Success"
         cd "${RUNDIR}"
      fi
   done
}

function StageDistroRpms {
   local ITEM

   if [[ ! -d ${HOME}/RPM/${DISTRONAME} ]]
   then
      printf "Creating %s... " "${HOME}/RPM/${DISTRONAME}"
      install -dDm 0755 "${HOME}/RPM/${DISTRONAME}" || \
        err_exit "Failed to create ${HOME}/RPM/${DISTRONAME}"
      echo "Success"
   fi

   (
     cd "${HOME}/RPM/${DISTRONAME}"

     for ITEM in "${REPORPMS[@]}"
     do
        printf "fetching %s to %s... " "${ITEM}" \
          "${HOME}/RPM/${DISTRONAME}"
        curl -sOkL "${ITEM}"
        echo "Success"
     done
   )
}



######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
  -o d:hk:r: \
  --long distro-name:,help,repo-rpms:,sign-keys:, \
  -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -d|--distro-name)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  DISTRONAME="${2}"
                  shift 2;
                  ;;
            esac
            ;;
      -h|--help)
            UsageMsg 0
            ;;
      -k|--sign-keys)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  IFS=, read -ra PKGSIGNKEYS <<< "$2"
                  shift 2;
                  ;;
            esac
            ;;
      -r|--repo-rpms)
            case "$2" in
               "")
                  err_exit "Error: option required but not specified"
                  shift 2;
                  exit 1
                  ;;
               *)
                  IFS=, read -ra REPORPMS <<< "$2"
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

# Ensure we have our arguments
if [[ ${#REPORPMS[*]} -eq 0 ]] ||
   [[ ${#PKGSIGNKEYS[*]} -eq 0 ]] ||
   [[ -z ${DISTRONAME} ]]
then
   UsageMsg 1
fi

InstallGpgKeys
StageDistroRpms
