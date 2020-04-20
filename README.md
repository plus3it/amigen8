# Introduction

This project contains the build-automation for creating LVM-enabled Enterprise Linux 8 AMIs for use in AWS envrionments. Testing and support will be given to RHEL 8 and CentOS8. Other EL8-derivatives should also work, but will not be specifically tested by the project-owners.

## Status

Recent needs have caused us to have to move ahead with this project, even in the absence of an official AMI published to the AWS MarketPlace by CentOS.Org.

As of this writing (April 17<sup>th</sup>, 2020), the project-content is "first pass". It produces a CentOS 8.1.1911 AMI. The AMI has a default root-EBS of 20GiB. That EBS is organized via a GPT partition table. The boot record is stored on the EBS's first slice. The first slice is 16MiB in size and does not contain a filesystem. The CentOS 8 operating system is installed to the root-EBS's second slice. The second slice is nearly 20GiB in size and is subdivided as follows:

~~~
Filesystem                   Size  Used Avail Use% Mounted on
devtmpfs                     922M     0  922M   0% /dev
tmpfs                        958M     0  958M   0% /dev/shm
tmpfs                        958M  426k  958M   1% /run
tmpfs                        958M     0  958M   0% /sys/fs/cgroup
/dev/mapper/RootVG-rootVol   4.3G  2.0G  2.4G  46% /
tmpfs                        958M  4.1k  958M   1% /tmp
/dev/mapper/RootVG-varVol    2.2G  200M  2.0G  10% /var
/dev/mapper/RootVG-homeVol   1.1G   42M  1.1G   4% /home
/dev/mapper/RootVG-logVol    2.2G   67M  2.1G   4% /var/log
/dev/mapper/RootVG-auditVol  9.7G  102M  9.6G   2% /var/log/audit
tmpfs                        192M     0  192M   0% /run/user/1000
~~~

The installed operating system is derived from the "Core" RPM-group. In addition to the RPM-group's contents, the following CentOS RPMs (and dependencies) are included:

- chrony
- cloud-init
- cloud-utils-growpart
- dhcp-client
- dracut-config-generic
- firewalld
- gdisk
- grub2-pc-modules
- grub2-tools
- grub2-tools-minimal
- grubby
- kernel
- kexec-tools
- lvm2
- rng-tools
- unzip

Further, the AMI has been enabled with three AWS utility-packages (and associated dependencies):

- SSM Agent: The agent starts at EC2 launch and will result in the instance showing up in the account's SSM management-inventory
- AWS CLI v1 available if `/usr/local/bin` is in the user's or processes's `PATH` env. This path is linked from binaries in `/opt/aws/cli/bin`
- AWS CLI v2 available if `/usr/bin` is in the user's or processes's `PATH` env. This path is linked from binaries in `/opt/aws/cli/v2/bin`. 

Note<sup>1</sup>: If there is a preference for v1 or v2 of the AWS CLI, it will be necessary to order the user's or process's `PATH` env appropriately. Both have been verified to work as expected when a suitable instance-role is applied to the instance.

Note<sup>2</sup>: This project has no yet been proven to create functional RHEL 8 AMIs. Relevant testing and updates will occur "soon".

Note<sup>3</sup>: This project's scripts will also be usable to produce "bare partitioned" (no LVM2 used) AMIs. This functionality is primarily for project-maintainers' internal use and will not be extensively tested. As wih RHEL 8 capabilities, relevant baseline-functionality testing and updates will occur "soon".


## About the scripts

Each script accepts several flags to govern/customize operation. Similarly, each script can also be driven by setting appropriate environment variable values. For usage-summaries, each script may be invoked with a `-h` (or `--help`) flag. Primary flagging is via short-options; GNU-style long-options will reference their corresponding short-options in the usage-summaries.

The scripts should be used in the following order:

1. [DiskSetup.sh](docs/README_DiskSetup.md): Configures chroot-dev target-disk
1. [MkChrootTree.sh](docs/README_MkChrootTree.md): Mount's chroot-dev target-disk 
1. [OSpackages.sh](docs/README_OSpackages.md): Installs base OS RPMs into chroot-dev target-disk 
1. [AWSutils.sh](docs/README_AWSutils.md): Installs AWS utilities and dependencies into chroot-dev target-disk 
1. [PostBuild.sh](docs/README_PostBuild.md): Readies chroot-dev target-disk to be turned into an AMI
1. [Umount.sh](docs/README_Umount.md): Unmounts (and optionally nulls) the chroot-dev target-disk


After the `Umount.sh` script has executed, it will be safe to snapshot the build-targe EBS. Once the snapshot completes, an AMI can be safely registered.

Each of the scripts has been tested via interactive use. Each *should* work when automated through a framework like HashiCorp's Packer.
