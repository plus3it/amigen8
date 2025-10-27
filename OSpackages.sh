#!/bin/bash
set -eu -o pipefail
#
# Install primary OS packages into chroot-env
#
#######################################################################
PROGNAME=$(basename "$0")
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
GRUBPKGS_X86=(
    efibootmgr
    grub2-efi-x64
    grub2-efi-x64-modules
    grub2-pc
    grub2-pc-modules
    grub2-tools
    grub2-tools-efi
    grub2-tools-minimal
    shim-x64
)
MINXTRAPKGS=(
    chrony
    cloud-init
    cloud-utils-growpart
    dhcp-client
    dracut-config-generic
    firewalld
    gdisk
    grub2-pc-modules
    grub2-tools
    grub2-tools-minimal
    grubby
    kernel
    kexec-tools
    libnsl
    lvm2
    rng-tools
    unzip
)
EXCLUDEPKGS=(
    aic94xx-firmware
    alsa-firmware
    alsa-tools-firmware
    biosdevname
    iprutils
    ivtv-firmware
    iwl100-firmware
    iwl1000-firmware
    iwl105-firmware
    iwl135-firmware
    iwl2000-firmware
    iwl2030-firmware
    iwl3160-firmware
    iwl3945-firmware
    iwl4965-firmware
    iwl5000-firmware
    iwl5150-firmware
    iwl6000-firmware
    iwl6000g2a-firmware
    iwl6000g2b-firmware
    iwl6050-firmware
    iwl7260-firmware
    libertas-sd8686-firmware
    libertas-sd8787-firmware
    libertas-usb8388-firmware
    rhc
)
RPMFILE=${RPMFILE:-UNDEF}
RPMGRP=${RPMGRP:-core}

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
        printf '\t%-4s%s\n' '-a' 'List of repository-names to activate'
        printf '\t%-6s%s' '' 'Default activation: '
        GetDefaultRepos
        printf '\t%-4s%s\n' '-e' 'Extra RPMs to install from enabled repos'
        printf '\t%-4s%s\n' '-g' 'RPM-group to intall (default: "core")'
        printf '\t%-4s%s\n' '-h' 'Print this message'
        printf '\t%-4s%s\n' '-M' 'File containing list of RPMs to install'
        printf '\t%-4s%s\n' '-m' 'Where to mount chroot-dev (default: "/mnt/ec2-root")'
        printf '\t%-4s%s\n' '-r' 'List of repo-def repository RPMs or RPM-URLs to install'
        printf '\t%-4s%s\n' '-X' 'Declare to be a cross-distro build'
        printf '\t%-4s%s\n' '-x' 'List of RPMs to exclude from build-list'
        printf '\t%-20s%s\n' '--cross-distro' 'See "-X" short-option'
        printf '\t%-20s%s\n' '--exclude-rpms' 'See "-x" short-option'
        printf '\t%-20s%s\n' '--extra-rpms' 'See "-e" short-option'
        printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
        printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
        printf '\t%-20s%s\n' '--pkg-manifest' 'See "-M" short-option'
        printf '\t%-20s%s\n' '--repo-activation' 'See "-a" short-option'
        printf '\t%-20s%s\n' '--repo-rpms' 'See "-r" short-option'
        printf '\t%-20s%s\n' '--rpm-group' 'See "-g" short-option'
        printf '\t%-20s%s\n' '--setup-dnf' 'Addresses (OL8) distribution-specific DNF config-needs'
    )
    exit "${SCRIPTEXIT}"
}

# Default yum repository-list for selected OSes
function GetDefaultRepos {
    local -a BASEREPOS

    # Make sure we can use `rpm` command
    if [[ $(rpm -qa --quiet 2> /dev/null)$? -ne 0 ]]
    then
        err_exit "The rpm command not functioning correctly"
    fi

    case $( rpm -qf /etc/os-release --qf '%{name}' ) in
        centos-linux-release | centos-stream-release )
          BASEREPOS=(
              baseos
              appstream
              extras
          )
          ;;
        centos-release )
          BASEREPOS=(
              BaseOS
              AppStream
              extras
          )
          ;;
        redhat-release-server|redhat-release)
          BASEREPOS=(
              rhel-8-appstream-rhui-rpms
              rhel-8-baseos-rhui-rpms
              rhui-client-config-server-8
          )
          ;;
        oraclelinux-release)
          BASEREPOS=(
            ol8_UEKR6
            ol8_appstream
            ol8_baseos_latest
          )
          ;;
        *)
          echo "Unknown OS. Aborting" >&2
          exit 1
          ;;
    esac

    ( IFS=',' ; echo "${BASEREPOS[*]}" )
}

# Install base/setup packages in chroot-dev
function PrepChroot {
    local -a BASEPKGS
    local    DNF_ELEM
    local    DNF_FILE
    local    DNF_VALUE

    # Create an array of packages to install
    BASEPKGS=(
        yum-utils
    )

    # Don't try to be helpful if doing cross-distro (i.e., "bootstrapper-build")
    if [[ -z ${ISCROSSDISTRO:-} ]]
    then
        mapfile -t -O "${#BASEPKGS[@]}" BASEPKGS < <(
          rpm --qf '%{name}\n' -qf /etc/os-release ; \
          rpm --qf '%{name}\n' -qf  /etc/yum.repos.d/* 2>&1 | grep -v "not owned" | sort -u ; \
        )
    fi

    # Ensure DNS lookups work in chroot-dev
    if [[ ! -e ${CHROOTMNT}/etc/resolv.conf ]]
    then
        err_exit "Installing ${CHROOTMNT}/etc/resolv.conf..." NONE
        install -Dm 000644 /etc/resolv.conf "${CHROOTMNT}/etc/resolv.conf"
    fi

    # Ensure etc/rc.d/init.d exists in chroot-dev
    if [[ ! -e ${CHROOTMNT}/etc/rc.d/init.d ]]
    then
        install -dDm 000755 "${CHROOTMNT}/etc/rc.d/init.d"
    fi

    # Ensure etc/init.d exists in chroot-dev
    if [[ ! -e ${CHROOTMNT}/etc/init.d ]]
    then
        ln -t "${CHROOTMNT}/etc" -s ./rc.d/init.d
    fi

    # Satisfy weird, OL8-dependecy:
    # * Ensure the /etc/dnf and /etc/yum contents are present
    if [[ -n "${DNF_ARRAY:-}" ]]
    then
        err_exit "Execute DNF hack..." NONE
        for DNF_ELEM in "${DNF_ARRAY[@]}"
        do
          DNF_FILE=${DNF_ELEM//=*/}
          DNF_VALUE=${DNF_ELEM//*=/}

          err_exit "Creating ${CHROOTMNT}/etc/dnf/vars/${DNF_FILE}... " NONE
          install -bDm 0644 <(
            printf "%s" "${DNF_VALUE}"
          ) "${CHROOTMNT}/etc/dnf/vars/${DNF_FILE}" || err_exit Failed
          err_exit "Success" NONE
        done
    fi

    # Clean out stale RPMs
    if stat /tmp/*.rpm > /dev/null 2>&1
    then
        err_exit "Cleaning out stale RPMs..." NONE
        rm -f /tmp/*.rpm || \
          err_exit "Failed cleaning out stale RPMs"
    fi

    # Stage our base RPMs
    yumdownloader -y --destdir=/tmp "${BASEPKGS[@]}"
    if [[ ${REPORPMS:-} != '' ]]
    then
        FetchCustomRepos
    fi

    # Initialize RPM db in chroot-dev
    err_exit "Initializing RPM db..." NONE
    rpm --root "${CHROOTMNT}" --initdb || \
      err_exit "Failed initializing RPM db"

    # Install staged RPMs
    err_exit "Installing staged RPMs..." NONE
    rpm --force --root "${CHROOTMNT}" -ivh --nodeps --nopre /tmp/*.rpm || \
      err_exit "Failed installing staged RPMs"

    # Try to keep the yum RPM's reinstall from barfing on Azure
    AzureYumPluginDirCollision

    # Install dependences for base RPMs
    err_exit "Installing base RPM's dependences..." NONE
    yum --disablerepo="*" --enablerepo="${OSREPOS}" \
        --installroot="${CHROOTMNT}" -y reinstall "${BASEPKGS[@]}" || \
      err_exit "Failed installing base RPM's dependences"

    # Ensure yum-utils are installed in chroot-dev
    err_exit "Ensuring yum-utils are installed..." NONE
    yum --disablerepo="*" --enablerepo="${OSREPOS}" \
        --installroot="${CHROOTMNT}" -y install yum-utils || \
      err_exit "Failed installing yum-utils"

}

# Install selected package-set into chroot-dev
function MainInstall {
    local YUMCMD

    YUMCMD="yum --nogpgcheck --installroot=${CHROOTMNT} "
    YUMCMD+="--disablerepo=* --enablerepo=${OSREPOS} install -y "

    # If RPM-file not specified, use a group from repo metadata
    if [[ ${RPMFILE} == "UNDEF" ]]
    then
        # Expand the "core" RPM group and store as array
        mapfile -t INCLUDEPKGS < <(
          yum groupinfo "${RPMGRP}" 2>&1 | \
          sed -n '/Mandatory/,/Optional Packages:/p' | \
          sed -e '/^ [A-Z]/d' -e 's/^[[:space:]]*[-=+[:space:]]//'
        )

        # Don't assume that just because the operator didn't pass
        # a manifest-file that the repository is properly run and has
        # the group metadata that it ought to have
        if [[ ${#INCLUDEPKGS[*]} -eq 0 ]]
        then
          err_exit "Oops: unable to parse metadata from repos"
        fi
    # Try to read from local file
    elif [[ -s ${RPMFILE} ]]
    then
        err_exit "Reading manifest-file" NONE
        mapfile -t INCLUDEPKGS < "${RPMFILE}"
    # Try to read from URL
    elif [[ ${RPMFILE} =~ http([s]{1}|):// ]]
    then
        err_exit "Reading manifest from ${RPMFILE}" NONE
        mapfile -t INCLUDEPKGS < <( curl -sL "${RPMFILE}" )
        if [[ ${#INCLUDEPKGS[*]} -eq 0 ]] ||
          [[ ${INCLUDEPKGS[*]} =~ "Not Found" ]] ||
          [[ ${INCLUDEPKGS[*]} =~ "Access Denied" ]]
        then
          err_exit "Failed reading manifest from URL"
        fi
    else
        err_exit "The manifest file does not exist or is empty"
    fi

    # Add extra packages to include-list (array)
    INCLUDEPKGS=(
      "${INCLUDEPKGS[@]}"
      "${MINXTRAPKGS[@]}"
      "${EXTRARPMS[@]}"
    )

    if [[ -d /sys/firmware/efi ]]
    then
      INCLUDEPKGS+=( "${GRUBPKGS_X86[@]}" )
    fi

    # Remove excluded packages from include-list
    for EXCLUDE in "${EXCLUDEPKGS[@]}" "${EXTRAEXCLUDE[@]}"
    do
        INCLUDEPKGS=( "${INCLUDEPKGS[@]//*${EXCLUDE}*}" )
    done

    # Install packages
    YUMCMD+="$( IFS=' ' ; echo "${INCLUDEPKGS[*]}" )"
    ${YUMCMD} -x "$( IFS=',' ; echo "${EXCLUDEPKGS[*]}" )"

    # Verify installation
    err_exit "Verifying installed RPMs" NONE
    for RPM in "${INCLUDEPKGS[@]}"
    do
        if [[ -z "$RPM" ]]
        then
          continue
        fi
        err_exit "Checking presence of '${RPM}'..." NONE
        chroot "${CHROOTMNT}" bash -c "rpm -q ${RPM}" || \
          err_exit "Failed finding ${RPM}"
    done

}

# Get custom repo-RPMs
function FetchCustomRepos {
    local REPORPM

    for REPORPM in ${REPORPMS//,/ }
    do
        if [[ ${REPORPM} =~ http[s]*:// ]]
        then
          err_exit "Fetching ${REPORPM} with curl..." NONE
          ( cd /tmp && curl --connect-timeout 15 -O  -sL "${REPORPM}" ) || \
            err_exit "Fetch failed"
        else
          err_exit "Fetching ${REPORPM} with yum..." NONE
          yumdownloader --destdir=/tmp "${REPORPM}" > /dev/null 2>&1 || \
            err_exit "Fetch failed"
        fi
    done

}

# Prevent Azure-specific failure
function AzureYumPluginDirCollision {
    local AZURE_ASSET_TAG
    local YUM_PROBLEM_DIR

    # The asset-tag value for dmidecode see reference:
    #   https://learn.microsoft.com/en-us/azure/automation/troubleshoot/update-agent-issues-linux#dmidecode-check
    # For ID string-value
    AZURE_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"

    # The directory that the Azure-RHUI version of yum doesn't like
    YUM_PROBLEM_DIR="${CHROOTMNT}/etc/yum/pluginconf.d"

    # Check if dmidecode RPM is installed (return if not)
    if [[ $( rpm -q dmidecode --quiet )$? -ne 0 ]]
    then
      err_exit "The dmidecode utility is not available. Cannot check virtualization-platform" NONE
      return
    fi

    # Nuke YUM_PROBLEM_DIR if present and we're on Azure
    if [[ $( dmidecode --string chassis-asset-tag ) == "${AZURE_ASSET_TAG}" ]] &&
      [[ -d ${YUM_PROBLEM_DIR} ]]
    then
      err_exit "Deleting ${YUM_PROBLEM_DIR} on an Azure build-host..." NONE
      rm -rf "${YUM_PROBLEM_DIR}" || err_exit "Failed deleting ${YUM_PROBLEM_DIR}. Aborting... " 1
      err_exit "Successfully deleted ${YUM_PROBLEM_DIR}" NONE
    fi
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
    -o a:e:Fg:hM:m:r:Xx: \
    --long cross-distro,exclude-rpms:,extra-rpms:,help,mountpoint:,pkg-manifest:,repo-activation:,repo-rpms:,rpm-group:,setup-dnf: \
    -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
    case "$1" in
        -a|--repo-activation)
              case "$2" in
                "")
                    err_exit "Error: option required but not specified"
                    shift 2;
                    exit 1
                    ;;
                *)
                    OSREPOS=${2}
                    shift 2;
                    ;;
              esac
              ;;
        -e|--extra-rpms)
              case "$2" in
                "")
                    echo "Error: option required but not specified" > /dev/stderr
                    shift 2;
                    exit 1
                    ;;
                *)
                    IFS=, read -ra EXTRARPMS <<< "$2"
                    shift 2;
                    ;;
              esac
              ;;
        -g|--rpm-group)
              case "$2" in
                "")
                    err_exit "Error: option required but not specified"
                    shift 2;
                    exit 1
                    ;;
                *)
                    RPMGRP=${2}
                    shift 2;
                    ;;
              esac
              ;;
        -h|--help)
              UsageMsg 0
              ;;
        --setup-dnf)
              case "$2" in
                "")
                    err_exit "Error: option required but not specified"
                    shift 2;
                    exit 1
                    ;;
                *)
                    IFS=, read -ra DNF_ARRAY <<< "$2"
                    shift 2;
                    ;;
              esac
              ;;
        -M|--pkg-manifest)
              case "$2" in
                "")
                    err_exit "Error: option required but not specified"
                    shift 2;
                    exit 1
                    ;;
                *)
                    RPMFILE=${2}
                    shift 2;
                    ;;
              esac
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
        -r|--repo-rpms)
              case "$2" in
                "")
                    err_exit "Error: option required but not specified"
                    shift 2;
                    exit 1
                    ;;
                *)
                    REPORPMS=${2}
                    shift 2;
                    ;;
              esac
              ;;
        -X|--cross-distro)
              ISCROSSDISTRO=TRUE
              shift
              ;;
        -x|--exclude-rpms)
              case "$2" in
                "")
                    echo "Error: option required but not specified" > /dev/stderr
                    shift 2;
                    exit 1
                    ;;
                *)
                    IFS=, read -ra EXTRAEXCLUDE <<< "$2"
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

# Repos to activate
if [[ ${OSREPOS:-} == '' ]]
then
    OSREPOS="$( GetDefaultRepos )"
fi

# Install minimum RPM-set into chroot-dev
PrepChroot

# Install the desired RPM-group or manifest-file
MainInstall

## Ensure desired repos are activated in the AMI ##
# disable any repo that might interfere
chroot "${CHROOTMNT}" /usr/bin/yum-config-manager --disable "*"

# Enable the requested list of repos
chroot "${CHROOTMNT}" /usr/bin/yum-config-manager --enable "${OSREPOS}"
