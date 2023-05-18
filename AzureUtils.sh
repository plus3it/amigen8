#!/bin/bash
set -eu -o pipefail
#
# Install, configure and activate Azure utilities and agents
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"

# Make interactive-execution more-verbose unless explicitly told not to
if [[ $( tty -s ) -eq 0 ]] && [[ ${DEBUG:-} == "UNDEF" ]]
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

   if [[ ${DEBUG:-} == true ]]
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

function AzCliSetup {
  # This function does not have to succeed

  if [[ $( rpm -q --quiet azure-cli )$? -ne 0 ]]
  then
    err_exit "Attempting to install azure-cli from Yum repo" NONE
    dnf --installroot="${CHROOTMNT}" \
      install --assumeyes --quiet azure-cli || \
      err_exit "WARNING: Azure CLI not installed" NONE
    err_exit "Success!" NONE
  fi
}

function MonitorAgentSetup {
  # This function does not have to succeed

  local STATUS_MSG

  # Check compatible FIPS-mode setting Per:
  #   https://learn.microsoft.com/en-us/azure/azure-monitor/agents/agent-linux?tabs=wrapper-script#supported-linux-hardening
  # Azure Log Analytics Agent is not supported on EL8 when FIPS mode is active
  if [[
    $( chroot "${CHROOTMNT}" /bin/bash -c "fips-mode-setup --check" ) == \
    "FIPS mode is enabled."
  ]]
  then
    STATUS_MSG="Azure Monitor Agent not supported on EL8"
    STATUS_MSG="${STATUS_MSG} when FIPS-mode is enabled."
    STATUS_MSG="${STATUS_MSG} See vendor-documentation."
    err_exit "${STATUS_MSG}" NONE
    return 0
  fi
}

function WaagentSetup {
  # This function MUST succeed
  local STATUS_MSG

  # This function configures the waagent service per the vendor-documentation:
  #
  # per https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-centos#centos-70
  #
  # Currently, the CentOS 7 guidance is the only guidance available. To date,
  # it's proven to work. This configuration-section will remain the same until
  # EL8-specific guidance has been released by the Azure team


  # If WALinuxAgent RPM is missing, attempt to install from yum-repos
  if [[ $( rpm -q --quiet WALinuxAgent )$? -ne 0 ]]
  then
    STATUS_MSG="The WALinuxAgent RPM is not installed."
    STATUS_MSG="${STATUS_MSG} Attempting to install."

    err_exit "${STATUS_MSG}" NONE
    dnf --installroot="${CHROOTMNT}" \
      install --assumeyes --quiet WALinuxAgent || \
      err_exit "Failed installing WALinuxAgent" 1
    err_exit "Success!" NONE

  fi

  err_exit "Configuring waagent..." NONE

  #  1. Install network-scripts
  err_exit "Installing RPM dependencies... " NONE
  dnf --installroot="${CHROOTMNT}" \
    install --assumeyes --quiet network-scripts || \
    err_exit "Failed installing RPM-dependencies" 1
  err_exit "Success!" NONE

  #  2. Enable network.service systemd unit
  err_exit "Enabling legacy network.service systemd unit " NONE
  err_exit "in %s... " "${CHROOTMNT}" NONE
  chroot "${CHROOTMNT}" systemctl enable network.service || \
    err_exit "Failed enabling network.service" 1
  err_exit "Success!" NONE

  #  3. Waagent wants an sysconfig/network config file
  if [[ ! -f ${CHROOTMNT}/etc/sysconfig/network ]]
  then
    err_exit "Creating config file for network.service... " NONE
    install -bDm 0600 -o root -g root /dev/null \
      "${CHROOTMNT}/etc/sysconfig/network"
    (
      echo "NETWORKING=yes"
      echo "HOSTNAME=localhost.localdomain"
    ) > "${CHROOTMNT}/etc/sysconfig/network" || \
      err_exit "Failed creating config file for network.service" 1
    err_exit "Success!" NONE
  fi

  #  4. Waagent wants an ifcfg-eth0 config file
  if [[ ! -f ${CHROOTMNT}/etc/sysconfig/network-scripts/ifcfg-eth0 ]]
  then
    err_exit "Creating ifcfg-eth0 file for network.service... " NONE
    install -bDm 0644 -o root -g root /dev/null \
      "${CHROOTMNT}/etc/sysconfig/network-scripts/ifcfg-eth0"
    (
      echo "DEVICE=eth0"
      echo "ONBOOT=yes"
      echo "BOOTPROTO=dhcp"
      echo "TYPE=Ethernet"
      echo "USERCTL=no"
      echo "PEERDNS=yes"
      echo "IPV6INIT=no"
      echo "NM_CONTROLLED=no"
    ) > "${CHROOTMNT}/etc/sysconfig/network-scripts/ifcfg-eth0" || \
      err_exit "Failed creating ifcfg-eth0 file for network.service" 1
    err_exit "Success!" NONE
  fi

  #  5. No static network-naming rules...
  err_exit "Disabling static udev network-naming rules... " NONE
  chroot "${CHROOTMNT}" ln -s /dev/null \
    /etc/udev/rules.d/75-persistent-net-generator.rules ||
    err_exit "Failed disabling static udev network-naming rules" 1
  err_exit "Success!" NONE

  #  6. Configure waagent for cloud-init
  #  For details on waagent config options, see: https://github.com/Azure/WALinuxAgent#configuration-file-options
  err_exit "Writing config-date to /etc/waagent.conf... " NONE
  chroot "${CHROOTMNT}" sed -i \
    -e 's/Provisioning.Agent=auto/Provisioning.Agent=auto/g' \
    -e 's/ResourceDisk.Format=y/ResourceDisk.Format=n/g' \
    -e 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/g' \
    /etc/waagent.conf || \
    err_exit "Failed writing config-date to /etc/waagent.conf" 1
  err_exit "Success!" NONE

  #  7. Allow only Azure datasource, disable fetching network setting via IMDS"
  err_exit "Configure Azure datasource... " NONE
  install -bDm 0644 -o root -g root <(
    echo "datasource_list: [ Azure ]"
    echo "datasource:"
    echo "  Azure:"
    echo "    apply_network_config: False"
  ) "${CHROOTMNT}/etc/cloud/cloud.cfg.d/91-azure_datasource.cfg" || \
    err_exit "Failed configuring Azure datasource" 1
  err_exit "Success!" NONE

  #  8. Add console log file
  err_exit "Configuring console-logging for cloud-init... " NONE
  install -bDm 0644 -o root -g root <(
    echo "# This tells cloud-init to redirect its stdout and stderr to"
    echo "# 'tee -a /var/log/cloud-init-output.log' so the user can see output"
    echo "# there without needing to look on the console."
    echo "output: {all: '| tee -a /var/log/cloud-init-output.log'}"
  ) "${CHROOTMNT}/etc/cloud/cloud.cfg.d/05_logging.cfg" || \
    err_exit "Failed configuring console-logging for cloud-init" 1
  err_exit "Success!" NONE

  # 9. Enable the services
  err_exit "Enabling the waagent.service systemd unit" NONE
  chroot "${CHROOTMNT}" systemctl enable waagent.service || \
    err_exit "Failed enabling waagent.service" 1
  err_exit "Success!" NONE
}

################
# Main Program #
################

# Ensure that AZ CLI is installed
AzCliSetup

# Ensure that Log Analytics Agent is installed
MonitorAgentSetup

# Ensure that Azure Linux Agent is installed
WaagentSetup

