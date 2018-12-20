#!/usr/bin/env bash

#---------------------------------------------------------------------------------------#
#                                                                                       #
# A script to backup your LXC containers to your favorite cloudstorage with Rclone.     #
# Usage: lxdbackup container-name                                                       #
# Author: Rosco Nap - cloudrkt.com/lxdbackup-script.html                                #
#                                                                                       #
# History:                                                                              #
# xx xxx xxxx  Rosco Nap   Initial Version Git: https://github.com/cloudrkt/lxdbackup   #
# 14 Dec 2018  knightmare  Updated with ISO date format YYYY-MM-DD-HH:MM                #
# 19 Dec 2018  knightmare  Use current MAC & IP Address of container in backup name,    #
#                          flesh out script, add more checks, help output, etc.         #
# 20 Dec 2018  knightmare  Fix output, make code more modular, remove redundnat code    #
#                                                                                       #
#---------------------------------------------------------------------------------------#
#                        How to restore MAC Address & IP Address                        #
#---------------------------------------------------------------------------------------#
# lxduser@lxd:~$ lxc init ubuntu:18.04 restoredvmname                                   #
# Creating restoredvmname                                                               #
# lxduser@lxd:~$ lxc network attach lxdbr0 restoredvmname eth0 eth0                     #
# lxduser@lxd:~$ lxc config device set restoredvmname eth0 hwaddr 00:0c:29:bc:e4:fe     #
# lxduser@lxd:~$ lxc config device set restoredvmname eth0 ipv4.address 10.69.123.210   #
# lxduser@lxd:~$ lxc start restoredvmname                                               #
#---------------------------------------------------------------------------------------#

## Settings
## The target bucket or container in your Rclone cloudstorage
RCLONETARGETDIR="lxdbackups"
## Optional Rclone settings.
RCLONEOPTIONS=""
## Rclone target cloud used in your rlcone.conf
RCLONETARGET="backuphosting"
## Directory were local images are stored before upload
WORKDIR="/tmp/lxdbackup"

## Help function
function help {
  echo
  echo "`basename $0` - A script to back up LXC/LXD Containers with rclone"
  echo
  echo "Usage: `basename $0` <container-name>"
  echo
  exit 1
  }

## If user gives -h, --help or no parameters, print help and exit
PARAMETERS=$#

while getopts ":nsh" PARAMETERS; do
  case $PARAMETERS in
    n) ## if command line option -c is given, we compile only ###
      LXCCONTAINER="$1"
    ;;
    s)
      echo different virtual network capability not implemented yet
      exit 0
    ;;
    *) ## any other parameters will always display help
       help
       exit 0
    ;;
  esac
done

## User ran the script without parameters, print help
if [ "$#" -ne 1 ]; then
  help
fi

exit 0

## Clean up when exiting unclean
trap "clean up; echo 'Unclean exit'" INT SIGHUP SIGINT SIGTERM

## Pre-flight checks. If the binaries don't exist, we're not backing anything up
for binary in date logger lxc rclone; do
location=`which "$binary"`
  if [ "$?" -eq 1 ]; then
    echo "Error: $binary command not found in path... cannot proceed"
    echo
    exit 0
  fi
done

## Check virtual bridge file exists, and add it as command line option. The MAC
## & IP checks only work if the container is booted, so be aware of that too.
if [ ! -f /var/lib/lxd/networks/lxdbr0/dnsmasq.leases ]; then
  echo 'virtual bridge file /var/lib/lxd/networks/lxdbr0/dnsmasq.leases does not exist, cannot determine MAC or IP Address'
  lecho 'virtual bridge file /var/lib/lxd/networks/lxdbr0/dnsmasq.leases does not exist, cannot determine MAC or IP Address'
  exit 0
fi

## Default behaviour
BACKUPDATE=$(date +"%Y-%m-%d_%H-%M")
CURRENTMAC=$(grep "$LXCCONTAINER" /var/lib/lxd/networks/lxdbr0/dnsmasq.leases | awk '{ print $2 }' | tr ':' '-')
CURRENTIP=$(grep "$LXCCONTAINER" /var/lib/lxd/networks/lxdbr0/dnsmasq.leases | awk '{ print $3 }' | tr '.' '_')

## Debug output
##echo Container "$1" with MAC: "$CURRENTMAC" is currently on IP address: "$CURRENTIP"

## Functions
lecho () {
  # log output to syslog
  logger "lxdbackup: $LXCCONTAINER - $@"
  echo $@
  }

## Checking backupdate
check_backupdate () {
  if [ -z "$BACKUPDATE" ]; then
    lecho "Could not determine backup date: $BACKUPDATE"
    return 1
  fi
  }

## Clean up the LXC snapshots
cleanup_snapshot () {
  check_backupdate
  if $LXC info $LXCCONTAINER|grep -q $BACKUPDATE; then
    if $LXC delete $LXCCONTAINER/$BACKUPDATE; then
      lecho "Clean up: Successfully deleted snapshot $LXCCONTAINER/$BACKUPDATE - $OUTPUT"
    else
      lecho "Clean up: Could not delete snapshot $LXCCONTAINER/$BACKUPDATE - $OUTPUT"
      return 1
    fi
  fi
  }

## Clean up the image created by LXC
cleanup_image () {
  check_backupdate
  if $LXC image info $LXCCONTAINER--BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE; then
    if $LXC image delete $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE; then
      lecho "Clean up: Successfully deleted copy $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE"
    else
      lecho "Clean up: Could not delete snapshot $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE"
      return 1
    fi
  fi
}

## Delete the published image from the local backupstore.
cleanup_published_image () {
  check_backupdate
  if [[ -f "$WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz" ]]; then
    if rm $WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz; then
      lecho "Clean up: Successfully deleted published image $WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz"
    else
      lecho "Clean up: Could not delete published image $WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz"
      return 1
    fi
  fi
}

## Aggregated clean up functions
cleanup () {
  cleanup_snapshot
  cleanup_image
  cleanup_published_image
  }

## Main backup script
main () {
  if [ ! -d "$WORKDIR" ]; then
    mkdir $WORKDIR && cd $WORKDIR
    lecho "Backup directory: $WORKDIR created for temporary backup storage"
  fi

  ## Change to the working directory for all the file store operations
  cd $WORKDIR

  ## Check lxc container is OK
  if $LXC info $LXCCONTAINER > /dev/null 2>&1 ; then
    lecho "Info: Container $LXCCONTAINER found, continuing.."
  else
    lecho "Info: Container $LXCCONTAINER NOT found, exiting lxdbackup"
    return 1
  fi

  ## Create snapshot with date as name
  if $LXC snapshot $LXCCONTAINER $BACKUPDATE; then
    lecho "Snapshot: Successfully created snapshot $BACKUPDATE on container $LXCCONTAINER"
  else
    lecho "Snapshot: Could not create snapshot $BACKUPDATE on container $LXCCONTAINER"
    return 1
  fi

  ## lxc publish --force container-name-backup-date --alias webserver-backup-date
  if $LXC publish --force $LXCCONTAINER/$BACKUPDATE --alias $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE; then
    lecho "Publish: Successfully published an image of $LXCCONTAINER-BACKUP-$BACKUPDATE to $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE"
  else
    lecho "Publish: Could not create image from $LXCCONTAINER-BACKUP-$BACKUPDATE to $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE"
    cleanup
    return 1
  fi

## Export lxc image to image.tar.gz file.
if $LXC image export $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE; then
  lecho "Image: Successfully exported an image of $LXCCONTAINER-BACKUP-$BACKUPDATE-IMAGE to $WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz"
else
  lecho "Image: Could not publish image from $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE to $WORKDIR/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz"
  cleanup
  exit 1
fi

  ## Create the cloudstore backup if does not exist.
  if $RCLONE mkdir $RCLONETARGET:$RCLONETARGETDIR; then
    lecho "Target directory: Successfully created the $RCLONETARGET:$RCLONETARGETDIR directory"
  else
    lecho "Target directory: Could not create the $RCLONETARGET:$RCLONETARGETDIR directory"
    cleanup
    return 1
  fi

  ## Upload the container image to the cloudstore backup.
  ## TODO: this can flub and still think it executed OK. Troubleshoot
  if $RCLONE $RCLONEOPTIONS copy $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz $RCLONETARGET:$RCLONETARGETDIR/$LXCCONTAINER/; then
    lecho "Upload: Successfully uploaded $LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz image to $RCLONETARGET:$RCLONETARGETDIR/$LXCCONTAINER/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz"
    cleanup
    lecho "Upload: Backup $BACKUPDATE for $LXCCONTAINER uploaded successfully to $RCLONETARGET."
  else
    lecho "Could not create the $RCLONETARGET:$RCLONETARGETDIR/$LXCCONTAINER/$LXCCONTAINER-BACKUP-$CURRENTMAC-$CURRENTIP-$BACKUPDATE-IMAGE.tar.gz on $RCLONETARGET:$RCLONETARGETDIR/$LXCCONTAINER/"
    cleanup
    return 1
  fi
  }

main
exit $?
