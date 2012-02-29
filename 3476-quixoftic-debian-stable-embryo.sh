#!/bin/bash
#
# Copyright (C) 2011 by Quixoftic, LLC <src@quixoftic.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# This Linode StackScript performs some basic security hardening for a
# newly-installed Debian stable Linode. It also creates a user account
# with an SSH key.

# <UDF name="hostname" label="The new system's hostname (NOT the FQDN, just the simple hostname, e.g., 'www')."/>
# <UDF name="domainname" label="The system's DNS domain name (e.g., 'quixoftic.com')."/>
# <UDF name="username" label="User account to create (will be added to sudo, adm groups)."/>
# <UDF name="userfullname" label="First and last name of user."/>
# <UDF name="passwd" label="*Encrypted* password."/>
# <UDF name="sshkey" label="ssh public key for above account"/>
# <UDF name="notifyemail" label="Send email to this address when installation is complete (optional)."/>

source <ssinclude StackScriptID=3480>

#
# Script begins here.
#

set -e
set -E
LOGFILE=~root/stackscript.log
enable_logging $LOGFILE

# Secure SSH first to shorten the brute-force window.
secure_ssh

# Upgrade and install some key packages.
safe_upgrade
apt_install etckeeper
apt_install heirloom-mailx

# Set the FQDN, and make sure that the resolver is updated by
# restarting the eth0 interface. This is overkill, but reloading
# resolvconf doesn't work reliably on Debian stable, at least.
apt_install resolvconf
resolvconf_set_domainname $DOMAINNAME
restart_interface eth0
etckeeper_commit "Set domain name to $DOMAINNAME."
set_hostname $HOSTNAME
etckeeper_commit "Set hostname to $HOSTNAME."

# Mail setup (null client config).
set_mailname $DOMAINNAME
etckeeper_commit "Set mailname to $DOMAINNAME."
install_postfix_null_client $DOMAINNAME
etckeeper_commit "postfix: null client config for domain $DOMAINNAME."

# At this point it's possible to send email.
[ -n "$NOTIFYEMAIL" ] && trap_with_failure_email "Linode VPS $HOSTNAME install FAILED." "$NOTIFYEMAIL" "$LOGFILE"

# All quixoftic.com systems use UTC.
set_timezone_to_utc
etckeeper_commit "Set timezone to UTC."

# All Quixoftic hosts require a separate /var/log device on /dev/xvdc,
# and encrypted swap on /dev/xvdb. Bail out if the Linode config
# profile didn't include them.
check_device /dev/xvdb
check_device /dev/xvdc

# Create user, add to admin groups.
apt_install sudo
add_user $USERNAME "$USERFULLNAME" $PASSWD
add_user_to_group $USERNAME sudo
add_user_to_group $USERNAME adm
etckeeper_commit "Add user $USERNAME (groups: sudo, adm)."

# Install user's ssh public key.
install_ssh_pubkey $USERNAME "$SSHKEY"

# Disable root history file, for security reasons.
disable_history_file root

# Move /var/log to a separate filesystem on /dev/xvdc.
copy_fs /var/log /dev/xvdc ext3 varlog

# Encrypted swap.
apt_install cryptsetup
crypttab_install_encrypted_swap /dev/xvdb
etckeeper_commit "Encrypted swap on /dev/xvdb."

# Fix up fstab for new /var/log and encrypted swap.
# Note: this is a bit too specialized to turn into a function, so
# we'll do it live.
echo "Creating a new /etc/fstab."
cp /etc/fstab /etc/fstab.orig
trap "mv /etc/fstab.orig /etc/fstab" ERR
rm -rf /etc/fstab
cat - > /etc/fstab<<EOF
# /etc/fstab: static file system information.
#
# <file system>         <mount point>   <type>   <options>                                 <dump>  <pass>
proc                    /proc           proc     defaults                                  0       0
/dev/mapper/swap        none            swap     sw                                        0       0
/dev/xvda               /               ext3     noatime,errors=remount-ro,barrier=0       0       1
/dev/xvdc               /var/log        ext3     noatime,nodev,nosuid,noexec,barrier=0     0       1
tmpfs                   /tmp            tmpfs    mode=1777,rw,nosuid,nodev                 0       0
EOF
rm /etc/fstab.orig
etckeeper_commit "Updated fstab."

# All Quixoftic hosts use the distro kernel and use pv-grub. Do this
# step late in the process, because the apt grub probes are slow.
apt_install linux-image-amd64
install_grub

# Cleanup.
apt_clean

if [ -n "$NOTIFYEMAIL" ] ; then
    mailx -s "Linode VPS $HOSTNAME install successful." "$NOTIFYEMAIL" <<EOF
Your install was successful!

You should reboot the host immediately with a pv-grub config profile.
Don't forget to disable the 'Xenify Distro' option!
EOF
fi

echo "Done! Reboot immediately with a pv-grub config profile."
echo "Don't forget to disable the 'Xenify Distro' option!"
exit 0
