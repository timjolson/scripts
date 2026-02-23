#!/bin/bash

# on receiver
# apt install openssh-server
# systemcl start ssh

# needs
DEST_USER="ubuntu"
IP="192.168.1.7"
DRIVE_LABEL="EDB6-478C"

nice -n 8 rsync -avP --remove-source-files --update /media/series/J/The\ Joe\ Rogan\ Experience\ \(2009\)\[tvdb-326959\]/ $DEST_USER@$IP:/media/ubuntu/$DRIVE_LABEL/media/series/J/The\ Joe\ Rogan\ Experience\ \(2009\)\[tvdb-326959\]/ --exclude 'tvshow.nfo' --exclude 'season.nfo'
