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

# This Linode StackScript upgrades a Debian stable Linode to Debian
# sid, installs all of the packages required to harden a Quixoftic
# Debian host, and creates a user account with an ssh key.

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

# Upgrade to sid and install some key packages.
upgrade_to_sid
apt_install etckeeper
apt_install heirloom-mailx

# Set the hostname, disable dhcpcd's ability to overwrite it.
apt_install resolvconf
resolvconf_set_domainname $DOMAINNAME
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

# All Quixoftic hosts use the distro kernel and use pv-grub.
apt_install linux-image-amd64
install_grub

# Install Quixoftic embryo meta-config package. This will harden the
# host properly and install all security-related packages.
add_quixoftic_apt_sources quixoftic-temp
etckeeper_commit "Add temporary Quixoftic apt sources and archive keyring."
install_quixoftic_meta_package embryo
remove_quixoftic_apt_sources quixoftic-temp
etckeeper_commit "Remove temporary Quixoftic apt sources."

# Move /var/log to a separate filesystem on /dev/xvdc (required for
# all Quixoftic hosts).
copy_fs /var/log /dev/xvdc ext3 varlog

# Create user, add to admin groups.
apt_install sudo
add_user $USERNAME "$USERFULLNAME" $PASSWD
add_user_to_group $USERNAME sudo
add_user_to_group $USERNAME adm
etckeeper_commit "Add user $USERNAME (groups: sudo, adm)."

# Install user's ssh public key.
install_ssh_pubkey $USERNAME "$SSHKEY"

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
