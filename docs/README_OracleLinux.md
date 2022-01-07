# Notes for Oracle Linux

This readme is intended to provide information specific to these scripts use for producing Oracle Linux (OL) AMIs

## Kernel Selection

If using the scripts' default mode, Oracle Linux will be installed using the `@core` RPM-group. Oracle, unlike Red Hat or the various Enterprise Linux distros, defines a customized kernel (the [Unbreakable Enterprise Kernel](https://docs.oracle.com/en/operating-systems/uek/), or "UEK") as its default kernel. This kernel not only contains OL8-specific, proprietary extensions, but is typically based off a different fork of the Linux 4.x kernel code. To minimize kernel-differences between the various Enterprise Linux distros this project publishes, this default is overridden. If using this project's contents and the UEK kernel is not desired, invoke the `OSpackages.sh` with the flag and option, `-x kernel-uek`

## DNF Uniqueness

Oracle Linux introduces distribution-specific build-order dependencies that effect the initial population of the build's target-disk not previously encountered by this project. In order to work past these dependencies and succesfully produce an OL8 image, it is necessary to invoke the `OSpackages.sh` script with the `--setup-dnf` toggle-flag. Failure to set this flag will result in the `OSpackages.sh` script failing during baseline population of the build process's target-disk with errors similar to:

~~~
Errors during downloading metadata for repository 'ol8_baseos_latest':
  - Curl error (6): Couldn't resolve host name for https://yum$ociregion.$ocidomain/repo/OracleLinux/OL8/baseos/latest/x86_64/repoda
ta/repomd.xml [Could not resolve host: yum$ociregion.$ocidomain]
Error: Failed to download metadata for repo 'ol8_baseos_latest': Cannot download repomd.xml: Cannot download repodata/repomd.xml: Al
l mirrors were tried
~~~

or:

~~~
File "/usr/lib/python3.6/site-packages/dnf/cli/cli.py", line 933, in _read_conf_file
    subst.update_from_etc(from_root, varsdir=conf._get_value('varsdir'))
~~~

Or, depending on any additional packages requested via the `-r` flag, something similar to:

~~~
oraclelinux-release-el8-1.0-21.el8    ########################################
error: failed to exec scriptlet interpreter /bin/sh: No such file or directory
warning: %post(oraclelinux-release-el8-1.0-21.el8.x86_64) scriptlet failed, exit status 127
error: failed to exec scriptlet interpreter /bin/sh: No such file or directory
warning: %posttrans(filesystem-3.8-6.el8.x86_64) scriptlet failed, exit status 127
~~~
