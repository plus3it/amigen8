#!/bin/bash
#
# Script to automate basic setup of CHROOT device
#
#################################################################
PROGNAME=$(basename "$0")
BOOTDEVSZ="500m"
FSTYPE="${FSTYPE:-ext4}"

# Function-abort hooks
trap "exit 1" TERM
export TOP_PID=$$

# Error-logging
function err_exit {
   echo "${1}" > /dev/stderr
   logger -t "${PROGNAME}" -p kern.crit "${1}"
   exit 1
}

# Print out a basic usage message
function UsageMsg {
   (
      echo "Usage: ${0} [GNU long option] [option] ..."
      echo "  Options:"
      printf '\t%-4s%s\n' '-B' 'Boot-partition size (default: 500MiB)'
      printf '\t%-4s%s\n' '-b' 'FS-label applied to boot-partition (default: /boot)'
      printf '\t%-4s%s\n' '-d' 'Base dev-node used for build-device'
      printf '\t%-4s%s\n' '-f' 'Filesystem-type used for root filesystems (default: xfs)'
      printf '\t%-4s%s\n' '-p' 'Comma-delimited string of colon-delimited partition-specs'
      printf '\t%-6s%s\n' '' 'Default layout:'
      printf '\t%-8s%s\n' '' '/:rootVol:4\n'
      printf '\t%-8s%s\n' '' 'swap:swapVol:2'
      printf '\t%-8s%s\n' '' '/home:homeVol:1'
      printf '\t%-8s%s\n' '' '/var:varVol:2'
      printf '\t%-8s%s\n' '' '/var/log:logVol:2'
      printf '\t%-8s%s\n' '' '/var/log/audit:auditVol:100%%FREE'
      printf '\t%-4s%s\n' '-r' 'Label to apply to root-partition if not using LVM (default: root_disk)'
      printf '\t%-4s%s\n' '-v' 'Name assigned to root volume-group (default: VolGroup00)'
      echo "  GNU long options:"
      printf '\t%-20s%s\n' '--bootlabel' 'See "-b" short-option'
      printf '\t%-20s%s\n' '--boot-size' 'See "-B" short-option'
      printf '\t%-20s%s\n' '--disk' 'See "-d" short-option'
      printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
      printf '\t%-20s%s\n' '--partition-string' 'See "-p" short-option'
      printf '\t%-20s%s\n' '--rootlabel' 'See "-r" short-option'
      printf '\t%-20s%s\n' '--vgname' 'See "-v" short-option'
   )
   exit 1
}

