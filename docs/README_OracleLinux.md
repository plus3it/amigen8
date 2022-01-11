# Notes for Oracle Linux

This readme is intended to provide information specific to these scripts use for producing Oracle Linux (OL) AMIs

## Kernel Selection

If using the scripts' default mode, Oracle Linux will be installed using the `@core` RPM-group. Oracle, unlike Red Hat or the various Enterprise Linux distros, defines a customized kernel (the [Unbreakable Enterprise Kernel](https://docs.oracle.com/en/operating-systems/uek/), or "UEK") as its default kernel. While this kernel is customized with notionally [open extensions](https://github.com/oracle/linux-uek), the baseline kernel used for adding those extensions is a different fork-point off the Linux kernel-project than the one used by Red Hat's distro &hellip;or the other distros that seek to be downstream clones of Red Hat's distro: Red Hat based it's kernel on [4.18.0](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html-single/8.0_release_notes/index#kernel); Oracle bases theirs on [5.4.17](https://docs.oracle.com/en/operating-systems/uek/). To minimize kernel-differences between the various Enterprise Linux distros this project publishes, this default is overridden. If readers of this document are using this project's contents and do not desire the use of the UEK kernel, invoke the `OSpackages.sh` with the flag and option, `-x kernel-uek`

## DNF Uniqueness

Oracle Linux introduces distribution-specific build-order dependencies that effect the initial population of the build's target-disk not previously encountered by this project. In order to work past these dependencies and successfully produce an OL8 image, it is necessary to invoke the `OSpackages.sh` script with the `--setup-dnf` variable-flag. This flag must be passed a comma-delimited list of variable-names and variable-values. For access to Oracle's public repositories, the recommended value for this flag is `ociregion=,ocidomain=oracle.com`. Failure to set this flag will result in the `OSpackages.sh` script failing during baseline population of the build process's target-disk with errors similar to:

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

**Note for use on isolated networks and/or partitions:**

These scripts have not been validated in scenarios where the Oracle yum repository is a private mirror. If when we have had an opportunity to deploy in such a context, this document and/or the associated documentation will be updated to reflect any issues encountered and how to work around them.
