# Introduction

The AMIgen utilities are typically used to generate AMIs from a starting-point (or, "bootstrap") AMIs. The starting-point AMIs may be selected from the AWS Marketplace (or CSP's equivalent), public AMIs or private AMIs. These starting-point AMIs must be the same distribution as the creation-target for the AMIgen scripts (e.g., use a Red Hat Enterprise Linux starting-point to create a Red Hat Enterprise Linux final AMI; use a Alma Linux starting-point to create a Alma Linux final AMI; etc.).

# Usage

Depending on your CSP's environment, there may be no suitable starting-point AMIs to use. If such is the case, use a procedure similar to the following to create such starting-point AMIs.

## Execute a `chroot()`-style build

1. Launch an EL8 AMI (probably RHEL8), ensuring that a secondary disk of at least 8GiB in size is attached
1. Install the `@development` package-group to the resultant EC2
1. Login to the EC2
1. Change to the `root` user (e.g., `sudo -i`)
1. Generate an RPM manifest suitable for your distro-clone (the ones marked `Mandatory` and `Default` from CentOS8 stream should be sufficient)
1. Clone the AMIgen8 project (this project) to the `root` user's `${HOME}`
1. Navigate into the AMIgen8 project-root (e.g., `cd AMIgen8`)
1. Use the `XdistroSetup.sh` script to stage the necessary alternate-disto GPG and repository files to the build-environment:
    ~~~
    ./XdistroSetup.sh -d <DISTRO_NAME> \
      -k <URL_TO_GPG_KEYFILE_1>,<URL_TO_GPG_KEYFILE_2>,...,<URL_TO_GPG_KEYFILE_n>, \
      -r <URL_TO_DISTRO_RELEASE_FILE_1>,<URL_TO_DISTRO_RELEASE_FILE_2>,...,<URL_TO_DISTRO_RELEASE_FILE_n>,
    ~~~
    For Rocky Linux 8, this would look something like:
    ~~~
    ./XdistroSetup.sh -d RockyLinux \
      -k https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-rockyofficial \
      -r https://download.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/Packages/r/rocky-release-8.5-2.el8.noarch.rpm,https://download.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/Packages/r/rocky-repos-8.5-2.el8.noarch.rpm
    ~~~
1. (Optional) Clean up target-disk by executing:
    ~~~
    ./Umount.sh -C <TARGET_DEV>
    ~~~
1. Partition the target-disk by executing:
    ~~~
    ./DiskSetup.sh -B 1024 -d <TARGET_DEV> -f xfs -r <FILESYSTEM_LABEL>
    ~~~
    Note: Selection of EXTn filesystem-types is also supported. Change the above `xfs`  and all following `xfs` references, as necessary, if an EXTn filesystem-type is chosen, instead.
1. Mount the target-disk by executing:
    ~~~
    ./MkChrootTree.sh -d <TARGET_DEV> -f xfs -m /mnt/ec2-root --no-lvm
    ~~~
1. Install the OS packages by executing:
    ~~~
    ./OSpackages.sh -a <LIST_OF_CHANNEL_NAMES> \
      -m /mnt/ec2-root -r /root/RPM/<DISTRO_NAME>/<DISTRO_RELEASE_RPM> \
      -X -M <MANIFEST_FILE>
    ~~~
    For Rocky Linux 8, this would look something like:
    ~~~
    ./OSpackages.sh -a baseos,appstream,extras \
      -m /mnt/ec2-root -X \
      -r /root/RPM/RockyLinux/rocky-repos-8.5-2.el8.noarch.rpm,/root/RPM/RockyLinux/rocky-release-8.5-2.el8.noarch.rpm \
      -x subscription-manager,redhat-rpm-config,rhn-check,rhn-client-tools,rhn-setup,rhnlib,rhnsd \
      -M <PATH_TO_MANIFEST_FILE>
    ~~~
    Note: Due to environment-inheritance when using a RHUI-enabled AMI, it's necessary to:
    * Exclude (with `-x`) all RPMs related to RHUI-enablement
    * Use a manifest-file rather than the groups-metadata that come from the RHUI repos
    * Staging the RPMs referenced with the `-r` flag is optional: if your build-host is able to pull those files from an anonymous repo, then the `-r` can be pointed to the relevant URLs. See per-platform notes below.
    * If bootstrapping to Oracle Linux 8, it will be necessary to export the `DNF_VAR_ocidomain` and `DNF_VAR_ociregion` environment variables. If using Oracle's public repositories, the values are `oracle.com` and `""`, respectively

1. (Optional) Install the AWS utilities by executing:
    ~~~
    ./AWSutils.sh -d ~/RPM/Amazon/ \
      -c <URL_OF_AWSCLIv2_BUNDLE> \
      -s <URL_OF_AWS_SSM_AGENT_RPM> \
      -m /mnt/ec2-root
    ~~~
    This will typically look something like:
    ~~~
    ./AWSutils.sh -d ~/RPM/Amazon/ \
      -c https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
      -s https://s3.us-east-1.amazonaws.com/amazon-ssm-us-east-1/latest/linux_amd64/amazon-ssm-agent.rpm \
      -m /mnt/ec2-root
    ~~~
    Note: If bootstrapping to Oracle Linux 8, see `DNF_VAR_*` note in the prior step
1. Apply SELinux labels, install GRUB2 stuff, etc., by executing:
    ~~~
    ./PostBuild.sh -f xfs -m /mnt/ec2-root -X -z <PREFERRED_TIMEZONE>
    ~~~
    This will typically look something like:
    ~~~
    ./PostBuild.sh -f xfs -m /mnt/ec2-root -X -z UTC
    ~~~
    Note: To ensure that the resultant AMI is _not_ FIPS-enabled, add the `--no-fips` long-option. Similarly, to ensure that `/tmp` is not set up as a `tmpfs` pseudo-filesyste, add the `--no-tmpfs`long-option.
1. Unmount the disk by executing:
    ~~~
    ./Umount.sh -c /mnt/ec2-root
    ~~~

## Create Image

Once the above, `chroot()`-style build to the secondary volume has successfully completed, you are ready to create an AMI from that secondary disk:

1. Using the AWS CLI or web-console, Snapshot the secondary volume
1. Create a suitable `blockmap.json` template-file. Contents should look like:
    ~~~
    [
        {
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "DeleteOnTermination": true,
                "SnapshotId": "__SNAPSHOT_ID__",
                "VolumeSize": __SIZE__,
                "VolumeType": "gp2"
            }
        }
    ]
    ~~~
    Note: `gp2` is the "normal" value. However, any EBS-type that's valid for the partition/region can be substituted. Simply be aware that select other than `gp2` may limit the instance-types that the resultant AMI can be launched as.
1. Monitor the snapshot's creation.
1. When the snapshot completes, register an image of it with something like:
    ~~~
    aws ec2 register-image \
      --virtualization-type hvm \
      --architecture x86_64 \
      --ena-support \
      --sriov-net-support simple \
      --root-device-name /dev/sda1 \
      --block-device-mappings "$(
          sed -e 's/__SIZE__/8/' -e 's/__SNAPSHOT_ID_/<SNAP_ID_FROM_1>/' /root/blockmap.json
        )" \
      --name "MyBootstrapAMI-YYYY.MM.N.x86_64-gp2" \
      --description "\"boostrap\" image for Rocky Linux 8.5 (current through 2021-12-21)"
    ~~~

## Validate Image

The above processes have been shown to reliably work for:

* Creating a CentOS 8 Core (now deprecated)
* Creating a CentOS 8 Stream
* Creating an Alma Linux 8
* Creating a Rocky Linux 8

When starting from an official Red Hat 8 AMI from the AWS MarketPlace (i.e., one maintained via CSP/Red Hat partnership). While this project has generically validated these scenarios, it is still a good idea to validate your results before trying to use your bootstrap AMI for AMI-building or other purposes. To do so:

1. Using the AWS CLI or web-console, launch an EC2 from your new bootstrapper AMI:
    * Ensure you launch it with an accessible SSH key
    * Ensure you launch it into an availability-zone reachable from your administration host
    * Ensure you attach a security-group that allows SSH-based access to the EC2 from your administration host
1. Monitor the EC2's startup. It should be ready to SSH into within 2-5 minutes. If the EC2 does not pass the two start-checks before then, the AMI is probably broken
1. SSH into the EC2's provisioning-user's account. Unless you have overridden this user either during the AMI-creation process or via the EC2's userData contents, the provisioning-user's account is `maintuser`
1. Elevate privileges to `root` (`sudo -i` should work without prompting for password)
1. Verify that the EC2 is running the expected Linux-distribution and release-level; executing `cat /etc/os-release` should produce output similar to:
    ~~~
    NAME="Rocky Linux"
    VERSION="8.5 (Green Obsidian)"
    ID="rocky"
    ID_LIKE="rhel centos fedora"
    VERSION_ID="8.5"
    PLATFORM_ID="platform:el8"
    PRETTY_NAME="Rocky Linux 8.5 (Green Obsidian)"
    ANSI_COLOR="0;32"
    CPE_NAME="cpe:/o:rocky:rocky:8:GA"
    HOME_URL="https://rockylinux.org/"
    BUG_REPORT_URL="https://bugs.rockylinux.org/"
    ROCKY_SUPPORT_PRODUCT="Rocky Linux"
    ROCKY_SUPPORT_PRODUCT_VERSION="8"
    ~~~
1. Verify that FIPS-mode is set as expected (`cat /proc/sys/crypto/fips_enabled`). By default, FIPS-mode will be enabled
1. Verify that the system consists of a single partition (e.g., `df -PHt xfs`)
1. Verify that the `/etc/fstab` file looks correct. This should be something like:
    ~~~
    LABEL=root_disk /       xfs     defaults         0 0
    ~~~
1. Verify that the `tmp.mount` service is active and that `/tmp` is a `tmpfs` filesystem:
    ~~~
    # systemctl status -l tmp.mount
    ● tmp.mount - Temporary Directory (/tmp)
        Loaded: loaded (/usr/lib/systemd/system/tmp.mount; enabled; vendor preset: disabled)
        Active: active (mounted) since Tue 2021-12-21 12:52:26 UTC; 3h 32min ago
          Where: /tmp
            What: tmpfs
            Docs: man:hier(7)
                https://www.freedesktop.org/wiki/Software/systemd/APIFileSystems
          Tasks: 0 (limit: 22949)
        Memory: 4.0K
        CGroup: /system.slice/tmp.mount
    ~~~
    And:
    ~~~
    # df -Ph /tmp
    Filesystem      Size  Used Avail Use% Mounted on
    tmpfs           1.8G  4.0K  1.8G   1% /tmp
    ~~~
1. Verify that the EC2 can talk to its `yum` repositories; executing `yum repoinfo | grep -E '^Repo-(name|pkgs)'` should produce output similar to:
    ~~~
    Last metadata expiration check: 0:01:00 ago on Tue Dec 21 16:02:16 2021.
    Repo-name          : Rocky Linux 8 - AppStream
    Repo-pkgs          : 6677
    Repo-name          : Rocky Linux 8 - BaseOS
    Repo-pkgs          : 1837
    Repo-name          : Rocky Linux 8 - Extras
    Repo-pkgs          : 37
    ~~~
1. Verify that the new AMI is fully up-to-date:
    ~~~
    # yum list updates
    Last metadata expiration check: 0:07:11 ago on Tue Dec 21 16:02:16 2021.
    #
    ~~~
    Note: If there are updates available, it's best to generate a new boostrap AMI and re-verify.
1. Verify that the AWS CLI is present:
    ~~~
    # find -L / -xdev -name aws -executable -type f
    /usr/local/bin/aws
    /usr/local/aws-cli/v1/bin/aws
    /usr/local/aws-cli/v2/2.4.6/dist/aws
    /usr/local/aws-cli/v2/2.4.6/bin/aws
    /usr/local/aws-cli/v2/current/dist/aws
    /usr/local/aws-cli/v2/current/bin/aws
    ~~~
1. Verify that the Amazon SSM agent is present:
    ~~~
    # rpm -qa amazon-ssm-agent
    amazon-ssm-agent-3.1.715.0-1.x86_64
    ~~~
1. If sharing the image, either set the image public (to be a good community-citizen) or share to the list of accounts that need to have access
1. If the bootstrap-images need to be multi-region (mostly if trying to be a good community-citizen), ensure to copy the verified-AMI from the region it was created in to any other region it should exist within.

# Per Platform Usage notes

## Alma Linux

As of this document's author-date, only the `almalinux-release-8.5-3.el8.x86_64.rpm` is needed for the `OSpackages.sh` script's repository-definition files (`-r`)


## CentOS 8 Stream

As of this document's author date, the `OSpackages.sh` script's repository-definition files (`-r`) need to include:

* `centos-gpg-keys`
* `centos-stream-release`
* `centos-stream-repos`

## Rocky Linux

As of this document's author date, the `OSpackages.sh` script's repository-definition files (`-r`) need to include:

* `rocky-repos`
* `rocky-release`
* `rocky-gpg-keys`

## Oracle Linux

Due to issues encountered with Oracle's RHEL8 clone's RPMs and repositories, this project's contents do not currently support use for generating Oracle bootstrap (or "final") AMIs. Please feel free to contribute relevant content.
