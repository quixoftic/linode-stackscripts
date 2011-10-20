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

function enable_logging {
    # Note: logs to both the screen and to a file. Just use "echo"
    # after calling this function and it'll show up on stdout and in
    # the file named by $1.
    if [ ! -n "$1" ] ; then
        echo "enable_logging function requires a filename."
        return 1
    fi
    local logfile="$1"
    exec 2>&1
    exec > >(tee -a $logfile)
}

function check_device {
    if [ ! -n "$1" ] ; then
        echo "check_device function requires a filename."
        return 1
    fi
    local devname="$1"
    if [ ! -b $devname ] ; then
        echo "Device $devname is missing."
        return 1
    fi
}

function safe_upgrade {
    echo "Upgrading packages (safe)."
    apt-get update
    apt-get -y install aptitude
    aptitude -y safe-upgrade
}

function apt_install {
    if [ ! -n "$1" ] ; then
        echo "apt_install function requires a package name."
        return 1
    fi
    echo "Installing $1"
    aptitude -y install $1
}

function install_grub {
    echo "Installing grub."
    mkdir /boot/grub
    apt_install grub-legacy
    # This command may return a non-zero error on a Linode, but that's OK.
    grub-set-default 1 || true
    update-grub

    echo "Modifying the generated grub menu.lst."
    sed -i -r 's/^# kopt=root=UUID=.*/# kopt=root=\/dev\/xvda console=hvc0 ro/' /boot/grub/menu.lst
    sed -i -r 's/^# groot=.*/# groot=(hd0)/' /boot/grub/menu.lst

    echo "Updating grub."
    update-grub
}

function copy_fs {
    # Copy a filesystem to a new device.
    #
    # Note: any existing filesystem on the target device will be
    # destroyed!
    #
    # Note: in general, it's not feasible to remount a filesystem with
    # open files, so this function neither remounts the new filesystem
    # in the old filesystem's place, nor does it remove the contents
    # of the old filesystem. You must reboot (with the corresponding
    # /etc/fstab) to do the former, and boot into a rescue OS to do
    # the latter.
    if [ ! -n "$1" ] ; then
        echo "copy_fs function requires a source filesystem."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "copy_fs function requires a target device."
        return 2
    fi
    local srcfs="$1"
    local destdev="$2"
    local fstype="ext3"
    if [ -n "$3" ] ; then
        fstype="$3"
    fi
    local label=""
    if [ -n "$4" ] ; then
        label="-L $4"
    fi
    echo "Preparing to copy $srcfs to $destdev."
    apt_install rsync
    echo "Making a new $fstype filesystem on $destdev."
    mkfs -t $fstype $label $destdev
    mount $destdev /mnt
    # Note: trailing "/" on $srcfs is crucial!
    echo "Copying $srcfs to $destdev."
    rsync -avx $srcfs/ /mnt
    umount /mnt
}

function crypttab_install_encrypted_swap {
    if [ ! -n "$1" ] ; then
        echo "crypttab_install_encrypted_swap function requires a target device."
        return 1
    fi
    local dev="$1"
    echo "Setting up encrypted swap on $dev."
    if [ ! -f /etc/crypttab ] ; then
        apt_install cryptsetup
    fi
    cat - >> /etc/crypttab<<EOF
swap                $dev               /dev/urandom         swap,cipher=aes-xts-plain
EOF
}

function set_timezone_to_utc {
    # Set timezone to Etc/UTC. tzdata doesn't really use debconf, so
    # easiest way is simply to remove /etc/localtime and
    # /etc/timezone, then reconfigure tzdata non-interactively. This
    # will set the time to Etc/UTC by default.
    echo "Setting timezone to Etc/UTC."
    rm -f /etc/localtime
    rm -f /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
}

function secure_ssh {
    # Disables ssh root login and password auth. Note that we try both
    # commented-out not commented-out versions of the original lines, for
    # safety.
    echo "Disabling ssh root login and password auth."
    sed -i -r 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i -r 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i -r 's/^#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i -r 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    /etc/init.d/ssh restart
}

function etckeeper_commit {
    if [ ! -n "$1" ] ; then
        echo "etckeeper_commit function requires a log message."
        return 1
    fi
    local logmsg="$1"
    etckeeper commit "$logmsg" || true
}

function resolvconf_set_domainname {
    if [ ! -n "$1" ] ; then
        echo "resolvconf_set_domainname function requires a domain name."
        return 1
    fi
    local domainname="$1"
    echo "Setting domain name to $domainname."
    # Note: the fact that this comes last in the generated resolv.conf
    # means it will override all other settings, including the "search
    # ..." directives inserted by dhcpcd.
    echo "domain $domainname" >> /etc/resolvconf/resolv.conf.d/tail
    /etc/init.d/resolvconf reload
}

function set_mailname {
    if [ ! -n "$1" ] ; then
        echo "set_mailname function requires a domain name."
        return 1
    fi
    local mailname=$1
    echo "Setting mailname to $mailname."
    rm -f /etc/mailname
    echo "$mailname" > /etc/mailname
}

function set_hostname {
    # Note: do this *after* setting the domain name in the resolver,
    # as that's where the hostname command gets the domain name.
    if [ ! -n "$1" ] ; then
        echo "set_hostname function requires a hostname."
        return 1
    fi
    local hname=$1
    echo "Setting hostname to $hname."
    rm -f /etc/hostname
    echo $hname > /etc/hostname
    hostname -F /etc/hostname

    # Make sure dhcpcd doesn't set the hostname from DHCP.
    sed -i -r "s/^SET_HOSTNAME='yes'$/#SET_HOSTNAME='yes'/" /etc/default/dhcpcd
    /etc/init.d/networking restart
}

function install_postfix_null_client {
    if [ ! -n "$1" ] ; then
        echo "install_postfix_null_client function requires a domain name."
        return 1
    fi
    local domainname=$1
    # Note: do this *after* setting mailname.
    echo "Installing Postfix configured as a null client (localhost only)."
    echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
    echo "postfix postfix/mailname string /etc/mailname" | debconf-set-selections
    apt_install postfix

    # Install sane defaults.
    cp /usr/share/postfix/main.cf.debian /etc/postfix/main.cf
    cp /usr/share/postfix/master.cf.dist /etc/postfix/master.cf
    postconf -e "mydomain = $domainname"
    postconf -e "myorigin = /etc/mailname"
    postconf -e "relayhost = \$mydomain"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "local_transport = error:local delivery is disabled"

    newaliases
    /etc/init.d/postfix restart
}

function home_dir {
    if [ ! -n "$1" ] ; then
        echo "home_dir function requires a username."
        return 1
    fi
    local username=$1
    getent passwd $username | cut -d ':' -f 6
}

function disable_history_file {
    if [ ! -n "$1" ] ; then
        echo "disable_history_file function requires a username."
        return 1
    fi
    local username=$1
    local homedir=$(home_dir $username)
    local bashrc=$homedir/.bashrc
    echo "Disabling history file for user $username."
    cat >> $bashrc <<EOF

unset HISTFILE
EOF
    chown $username:$username $bashrc
}

function add_user {
    if [ ! -n "$1" ] ; then
        echo "add_user function requires a username."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "add_user function requires a user full name."
        return 2
    fi
    if [ ! -n "$3" ] ; then
        echo "add_user function requires an encrypted password."
        return 3
    fi
    local username=$1
    local userfullname=$2
    local encpasswd=$3
    echo "Creating user $username."
    adduser --disabled-password --gecos "$userfullname,,,," $username
    chpasswd --encrypted<<EOF
$username:$encpasswd
EOF
    echo "Fixing $username's homedir permissions."
    local homedir=$(home_dir $username)
    chmod 0700 $homedir

    disable_history_file $username
}

function add_user_to_group {
    if [ ! -n "$1" ] ; then
        echo "add_user_to_group function requires a username."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "add_user_to_group function requires a group name."
        return 2
    fi
    echo "Adding user $1 to group $2."
    local username=$1
    local grpname=$2
    adduser $username $grpname
}

function install_ssh_pubkey {
    if [ ! -n "$1" ] ; then
        echo "install_ssh_pubkey function requires a username."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "install_ssh_pubkey function requires an ssh public key."
        return 2
    fi
    echo "Installing ssh public key for $1."
    local username=$1
    local pubkey="$2"
    local homedir=$(home_dir $username)
    local sshdir=$homedir/.ssh
    mkdir $sshdir
    echo $pubkey > $sshdir/authorized_keys
    chown -R $username:$username $sshdir
    chmod 0700 $sshdir
}

function send_failure_email {
    # Send a failure email with optional attachment.
    #
    # Note: you must have a mailx binary installed to use this
    # function (e.g., bsd-mailx or heirloom-mailx). Only
    # heirloom-mailx supports attachments.
    if [ ! -n "$1" ] ; then
        echo "send_failure_email function requires a subject."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "send_failure_email function requires a destination address."
        return 2
    fi
    local subject="$1"
    local dest="$2"
    local attachment=""
    if [ -n "$3" ] ; then
        attachment="-a $3"
    fi
    echo "Sending failure email to $dest."
    mailx -n $attachment -s "$subject" $dest <<EOF
Sorry, your install failed. There may be an attachment
with more information.
EOF
}

function trap_with_failure_email {
    # trap ERR: send a failure email with optional attachment.
    #
    # Note: you must set the -E flag for this to be effective with
    # functions.
    if [ ! -n "$1" ] ; then
        echo "enable_trap_failure_email function requires a subject."
        return 1
    fi
    if [ ! -n "$2" ] ; then
        echo "enable_trap_failure_email function requires a destination address."
        return 2
    fi
    local subject="$1"
    local dest="$2"
    local attachment=""
    if [ -n "$3" ] ; then
        attachment="$3"
    fi
    echo "Enabling installation failure emails."
    trap "send_failure_email \"$subject\" $dest $attachment" ERR
}

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
# <file system>         <mount point>   <type>   <options>                       <dump>  <pass>
proc                    /proc           proc     defaults                        0       0
/dev/mapper/swap        none            swap     sw                              0       0
/dev/xvda               /               ext3     noatime,errors=remount-ro       0       1
/dev/xvdc               /var/log        ext3     noatime,nodev,nosuid,noexec     0       1
tmpfs                   /tmp            tmpfs    mode=1777,rw,nosuid,nodev       0       0
EOF
rm /etc/fstab.orig
etckeeper_commit "Updated fstab."

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
