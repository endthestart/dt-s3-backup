#!/bin/bash

# The ROOT of your backup (where you want the backup to start);
# This can be / or somewhere else.
ROOT="/"

# BACKUP DESTINATION INFORMATION
# In my case, I use Amazon S3 use this - so I made up a unique
# bucket name (you don't have to have one created, it will do it
# for you).  If you don't want to use Amazon S3, you can backup
# to a file or any of duplicity's supported outputs.
#
# NOTE: You do need to keep the "s3+http://<your location>/" format
# even though duplicity supports "s3://<your location>/".
#DEST="s3+http://backup-bucket/backup-folder/"
DEST="scp://root@192.168.1.199//media/b01/carbonio"

# INCLUDE LIST OF DIRECTORIES
# Here is a list of directories to include; if you want to include
# everything that is in root, you could leave this list empty (I think).
#
# Here is an example with multiple locations:
INCLIST=( "/etc" "/home" "/media/cloud" "/media/storage" )
#
# Simpler example with one location:
#INCLIST=( "/home/foobar_user_name/Documents/Prose/" )

# EXCLUDE LIST OF DIRECTORIES
# If you have your root directory set to "/" duplicity will
# be all inclusive. So we need to exclude everything
# and this will make your INCLIST work properly.
# The config file already includes "**" to exclude
# anything that is not explicitly specified.
EXCLIST=( "/home/andermic/ownCloud" "/home/andermic/Downloads" "/home/andermic/Dropbox" )

# STATIC BACKUP OPTIONS
# Here you can define the static backup options that you want to run with
# duplicity.  I use both the `--full-if-older-than` option plus the
# `--s3-use-new-style` option (for European buckets).  Be sure to separate your
# options with appropriate spacing.
# --s3-use-rrs uses reduced redundancy and is an option that
# is only available in newer versions of duplicity
STATIC_OPTIONS="--full-if-older-than 14D --asynchronous-upload"

# FULL BACKUP & REMOVE OLDER THAN SETTINGS
# Because duplicity will continue to add to each backup as you go,
# it will eventually create a very large set of files.  Also, incremental
# backups leave room for problems in the chain, so doing a "full"
# backup every so often isn't not a bad idea.
#
# You can either remove older than a specific time period:
#CLEAN_UP_TYPE="remove-older-than"
#CLEAN_UP_VARIABLE="31D"

# Or, If you would rather keep a certain (n) number of full backups (rather
# than removing the files based on their age), you can use what I use:
CLEAN_UP_TYPE="remove-all-but-n-full"
CLEAN_UP_VARIABLE="2"

# LOGFILE INFORMATION DIRECTORY
# Provide directory for logfile, ownership of logfile, and verbosity level.
# I run this script as root, but save the log files under my user name --
# just makes it easier for me to read them and delete them as needed.

LOGDIR="/var/log/duplicity/"
LOG_FILE="duplicity-`date +%Y-%m-%d_%H-%M`.log"
LOG_FILE_OWNER="root:root"
VERBOSITY="-v4"

# EMAIL ALERT (*thanks: rmarescu*)
# Provide an email address to receive the logfile by email. If no email
# address is provided, no alert will be sent.
# You can set a custom from email address and a custom subject (both optionally)
# If no value is provided for the subject, the following value will be
# used by default: "DT-S3 Alert ${LOG_FILE}"
# MTA used: mailx
#EMAIL="admin@example.com"
#EMAIL_TO=
#EMAIL_FROM=
#EMAIL_SUBJECT=

# TROUBLESHOOTING: If you are having any problems running this script it is
# helpful to see the command output that is being generated to determine if the
# script is causing a problem or if it is an issue with duplicity (or your
# setup).  Simply  uncomment the ECHO line below and the commands will be
# printed to the logfile.  This way, you can see if the problem is with the
# script or with duplicity.
#ECHO=$(which echo)

##############################################################
# Script Happens Below This Line - Shouldn't Require Editing #
##############################################################
LOGFILE="${LOGDIR}${LOG_FILE}"
DUPLICITY="$(which duplicity)"
MAIL="$(which mailx)"

README_TXT="In case you've long forgotten, this is a backup script that you used to backup some files.  In order to restore these files, you first need to import your GPG private key (if you haven't already).  The key is in this directory and the following command should do the trick:\n\ngpg --allow-secret-key-import --import s3-secret.key.txt\n\nAfter your key as been succesfully imported, you should be able to restore your files.\n\nGood luck!"
CONFIG_VAR_MSG="Oops!! ${0} was unable to run!\nWe are missing one or more important variables at the top of the script.\nCheck your configuration because it appears that something has not been set yet."

if [ ! -x "$DUPLICITY" ]; then
  echo "ERROR: duplicity not installed, check your distribution's documentation" >&2
  exit 1
elif  [ `echo ${DEST} | cut -c 1,2` = "s3" ]; then
  if [ ! -x "$S3CMD" ]; then
    echo $NO_S3CMD; S3CMD_AVAIL=false
  elif [ ! -f "${HOME}/.s3cfg" ]; then
    echo $NO_S3CMD_CFG; S3CMD_AVAIL=false
  else
    S3CMD_AVAIL=true
  fi
fi

if [ ! -d ${LOGDIR} ]; then
  echo "Attempting to create log directory ${LOGDIR} ..."
  if ! mkdir -p ${LOGDIR}; then
    echo "Log directory ${LOGDIR} could not be created by this user: ${USER}"
    echo "Aborting..."
    exit 1
  else
    echo "Directory ${LOGDIR} successfully created."
  fi
elif [ ! -w ${LOGDIR} ]; then
  echo "Log directory ${LOGDIR} is not writeable by this user: ${USER}"
  echo "Aborting..."
  exit 1
fi

get_source_file_size()
{
  echo "---------[ Source File Size Information ]---------" >> ${LOGFILE}

  for exclude in ${EXCLIST[@]}; do
    DUEXCLIST="${DUEXCLIST}${exclude}\n"
  done

  for include in ${INCLIST[@]}
    do
      echo -e $DUEXCLIST | \
      du -hs --exclude-from="-" ${include} | \
      awk '{ print $2"\t"$1 }' \
      >> ${LOGFILE}
  done
  echo >> ${LOGFILE}
}

get_remote_file_size()
{
  echo "------[ Destination File Size Information ]------" >> ${LOGFILE}
  if [ `echo ${DEST} | cut -c 1,2` = "fi" ]; then
    TMPDEST=`echo ${DEST} | cut -c 6-`
    SIZE=`du -hs ${TMPDEST} | awk '{print $1}'`
  elif [ `echo ${DEST} | cut -c 1,2` = "s3" ] &&  $S3CMD_AVAIL ; then
      TMPDEST=$(echo ${DEST} | cut -c 11-)
      SIZE=`s3cmd du -H s3://${TMPDEST} | awk '{print $1}'`
  else
      SIZE="s3cmd not installed."
  fi
  echo "Current Remote Backup File Size: ${SIZE}" >> ${LOGFILE}
  echo >> ${LOGFILE}
}

include_exclude()
{
  for include in ${INCLIST[@]}
    do
      TMP=" --include="$include
      INCLUDE=$INCLUDE$TMP
  done
  for exclude in ${EXCLIST[@]}
      do
      TMP=" --exclude "$exclude
      EXCLUDE=$EXCLUDE$TMP
    done
    EXCLUDEROOT="--exclude=**"
}

duplicity_cleanup()
{
  echo "-----------[ Duplicity Cleanup ]-----------" >> ${LOGFILE}
  ${ECHO} ${DUPLICITY} ${CLEAN_UP_TYPE} ${CLEAN_UP_VARIABLE} ${STATIC_OPTIONS} --force \
        --encrypt-key=${GPG_KEY} \
        --sign-key=${GPG_KEY} \
        ${DEST} >> ${LOGFILE}
  echo >> ${LOGFILE}
}

duplicity_backup()
{
  ${ECHO} ${DUPLICITY} ${OPTION} ${VERBOSITY} ${STATIC_OPTIONS} \
  --encrypt-key=${GPG_KEY} \
  --sign-key=${GPG_KEY} \
  ${EXCLUDE} \
  ${INCLUDE} \
  ${EXCLUDEROOT} \
  ${ROOT} ${DEST} \
  >> ${LOGFILE}
}

get_file_sizes()
{
  get_source_file_size
  get_remote_file_size

  sed -i '/-------------------------------------------------/d' ${LOGFILE}
  chown ${LOG_FILE_OWNER} ${LOGFILE}
}

backup_this_script()
{
  if [ `echo ${0} | cut -c 1` = "." ]; then
    SCRIPTFILE=$(echo ${0} | cut -c 2-)
    SCRIPTPATH=$(pwd)${SCRIPTFILE}
  else
    SCRIPTPATH=$(which ${0})
  fi
  TMPDIR=dt-s3-backup-`date +%Y-%m-%d`
  TMPFILENAME=${TMPDIR}.tar.gpg
  README=${TMPDIR}/README

  echo "You are backing up: "
  echo "      1. ${SCRIPTPATH}"
  echo "      2. GPG Secret Key: ${GPG_KEY}"
  echo "Backup will be saved to: `pwd`/${TMPFILENAME}"
  echo
  echo ">> Are you sure you want to do that ('yes' to continue)?"
  read ANSWER
  if [ "$ANSWER" != "yes" ]; then
    echo "You said << ${ANSWER} >> so I am exiting now."
    exit 1
  fi

  mkdir -p ${TMPDIR}
  cp $SCRIPTPATH ${TMPDIR}/
  gpg -a --export-secret-keys ${GPG_KEY} > ${TMPDIR}/s3-secret.key.txt
  echo -e ${README_TXT} > ${README}
  echo "Encrypting tarball, choose a password you'll remember..."
  tar c ${TMPDIR} | gpg -aco ${TMPFILENAME}
  rm -Rf ${TMPDIR}
  echo -e "\nIMPORTANT!!"
  echo ">> To restore these files, run the following (remember your password):"
  echo "gpg -d ${TMPFILENAME} | tar x"
  echo -e "\nYou may want to write the above down and save it with the file."
}

check_variables ()
{
  if [[ ${ROOT} = "" || ${DEST} = "" || ${INCLIST} = "" || \
        ${AWS_ACCESS_KEY_ID} = "foobar_aws_key_id" || \
        ${AWS_SECRET_ACCESS_KEY} = "foobar_aws_access_key" || \
        ${GPG_KEY} = "foobar_gpg_key" || \
        ${PASSPHRASE} = "foobar_gpg_passphrase" ]]; then
    echo -e ${CONFIG_VAR_MSG}
    echo -e ${CONFIG_VAR_MSG}"\n--------    END    --------" >> ${LOGFILE}
    exit 1
  fi
}

echo -e "--------    START DT-S3-BACKUP SCRIPT    --------\n" >> ${LOGFILE}

if [ "$1" = "--backup-script" ]; then
  backup_this_script
  exit
elif [ "$1" = "--full" ]; then
  check_variables
  OPTION="full"
  include_exclude
  duplicity_backup
  duplicity_cleanup
  get_file_sizes

elif [ "$1" = "--verify" ]; then
  check_variables
  OLDROOT=${ROOT}
  ROOT=${DEST}
  DEST=${OLDROOT}
  OPTION="verify"

  echo -e "-------[ Verifying Source & Destination ]-------\n" >> ${LOGFILE}
  include_exclude
  duplicity_backup

  OLDROOT=${ROOT}
  ROOT=${DEST}
  DEST=${OLDROOT}

  get_file_sizes

  echo -e "Verify complete.  Check the log file for results:\n>> ${LOGFILE}"

elif [ "$1" = "--restore" ]; then
  check_variables
  ROOT=$DEST
  OPTION="restore"

  if [[ ! "$2" ]]; then
    echo "Please provide a destination path (eg, /home/user/dir):"
    read -e NEWDESTINATION
    DEST=$NEWDESTINATION
        echo ">> You will restore from ${ROOT} to ${DEST}"
        echo "Are you sure you want to do that ('yes' to continue)?"
        read ANSWER
        if [[ "$ANSWER" != "yes" ]]; then
            echo "You said << ${ANSWER} >> so I am exiting now."
            echo -e "User aborted restore process ...\n" >> ${LOGFILE}
            exit 1
        fi
  else
    DEST=$2
  fi

  echo "Attempting to restore now ..."
  duplicity_backup

elif [ "$1" = "--restore-file" ]; then
  check_variables
  ROOT=$DEST
  INCLUDE=
  EXCLUDE=
  EXLUDEROOT=
  OPTION=

  if [[ ! "$2" ]]; then
    echo "Which file do you want to restore (eg, mail/letter.txt):"
    read -e FILE_TO_RESTORE
    FILE_TO_RESTORE=$FILE_TO_RESTORE
    echo
  else
    FILE_TO_RESTORE=$2
  fi

  if [[ "$3" ]]; then
        DEST=$3
    else
    DEST=$(basename $FILE_TO_RESTORE)
    fi

  echo -e "YOU ARE ABOUT TO..."
  echo -e ">> RESTORE: $FILE_TO_RESTORE"
  echo -e ">> TO: ${DEST}"
  echo -e "\nAre you sure you want to do that ('yes' to continue)?"
  read ANSWER
  if [ "$ANSWER" != "yes" ]; then
    echo "You said << ${ANSWER} >> so I am exiting now."
    echo -e "--------    END    --------\n" >> ${LOGFILE}
    exit 1
  fi

  echo "Restoring now ..."
  #use INCLUDE variable without create another one
  INCLUDE="--file-to-restore ${FILE_TO_RESTORE}"
  duplicity_backup

elif [ "$1" = "--list-current-files" ]; then
  check_variables
  OPTION="list-current-files"
  ${DUPLICITY} ${OPTION} ${VERBOSITY} ${STATIC_OPTIONS} \
  --encrypt-key=${GPG_KEY} \
  --sign-key=${GPG_KEY} \
  ${DEST}
    echo -e "--------    END    --------\n" >> ${LOGFILE}

elif [ "$1" = "--backup" ]; then
  check_variables
  include_exclude
  duplicity_backup
  duplicity_cleanup
  get_file_sizes

else
  echo -e "[Only show `basename $0` usage options]\n" >> ${LOGFILE}
  echo "  USAGE:
    `basename $0` [options]

  Options:
    --backup: runs an incremental backup
    --full: forces a full backup

    --verify: verifies the backup
    --restore [path]: restores the entire backup
    --restore-file [file] [destination/filename]: restore a specific file
    --list-current-files: lists the files currently backed up in the archive

    --backup-script: automatically backup the script and secret key to the current working directory

  CURRENT SCRIPT VARIABLES:
  ========================
    DEST (backup destination) = ${DEST}
    INCLIST (directories included) = ${INCLIST[@]:0}
    EXCLIST (directories excluded) = ${EXCLIST[@]:0}
    ROOT (root directory of backup) = ${ROOT}
  "
fi

echo -e "--------    END DT-S3-BACKUP SCRIPT    --------\n" >> ${LOGFILE}

if [ $EMAIL_TO ]; then
    if [ ! -x "$MAIL" ]; then
        echo -e "Email coulnd't be sent. mailx not available." >> ${LOGFILE}
    else
        EMAIL_FROM=${EMAIL_FROM:+"-r ${EMAIL_FROM}"}
        EMAIL_SUBJECT=${EMAIL_SUBJECT:="DT-S3 Alert ${LOG_FILE}"}
        cat ${LOGFILE} | ${MAIL} -s """${EMAIL_SUBJECT}""" $EMAIL_FROM ${EMAIL_TO}
        echo -e "Email alert sent to ${EMAIL_TO} using ${MAIL}" >> ${LOGFILE}
    fi
fi

if [ ${ECHO} ]; then
  echo "TEST RUN ONLY: Check the logfile for command output."
fi

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset PASSPHRASE

# vim: set tabstop=2 shiftwidth=2 sts=2 autoindent smartindent:
