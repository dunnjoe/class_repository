#!/bin/bash

# enhancement check the value of wsrep_local_recv_queue and either wait for time or this to reach zero before stopping desync
# enhancement get datadir from the /etc/my.cnf file
# enhancement get socket from the /etc/my.cnf file
# enhancement lowercase all messages, remove extra #
# enhancement multiple log files and remove old ones
# enhancement better removal of old backups. based on actual date. 
# enhancement don't wipe out logfile if only help option requested. 

# 
# subrountines 
#
send_email(){
	msg=$1
	subj=$2
	mail -s "$subj" "$EMAIL" <<!
		$msg
!

}

# generic log writer to add time stamp to all messages
do_log(){
	log=$1
	log_date=`date +"%Y%m%d-%H%M%S"`	# get a date for log message
	echo "$log_date $log"  >> $LOGFILE
}

# mainline starts here

echo "run with -x option to see help\n"
# now under svn control 
SVN_VERSION="$Id: xtra.sh 319 2017-01-19 13:44:22Z jdanilson $"		# get svn version info in a variable


. $HOME/.bash_profile > /dev/null

DATE=$(date)
EMAIL="mysql_dba@uspto.gov"
HOST=$(hostname)

MESSAGE1="Percona backup failed in $HOST"
SUBJECT1=$MESSAGE1

LOG_BASE="/backup/email"
mkdir -p $LOG_BASE
LOGFILE="$LOG_BASE/LOGFILE"
echo "" > $LOGFILE   # initialize it for future communications
do_log "starting backup"

# setup default values
desync=-1		# we hope they never give us a negative number!
keep=1;
day=`date '+%Y%m%d%H%M'`;

# all backups go under $backup_root, even if user names the directory
backup_root="/backup/percona"
xbkup_dir="${backup_root}/xbkup_$day";

dir="/MYSIDS/mysql/etc";
datadir=/MYSIDS/mysql/data

dflts=/home/mysql/.my.cnf
cnf=/etc/my.cnf
compress=""
parallel=" --parallel=10 "
history=""
reset_bitmaps=0
galara_info=""
stream_host=""

# read command line arguments
while getopts c:d:k:p:s:t:h:rxg opt; do
  case $opt in
  c)
    compress=" --compress --compress-threads=$OPTARG "
    ;;
  h)
    history=" --history "
    ;;
  d)
    xbkup_dir=" ${backup_root}/$OPTARG"
    ;;
  p)
    parallel=" --parallel=$OPTARG "
    ;;
  k)
    keep=$OPTARG
    ;;
  r) 
    reset_bitmaps=1
    ;;
  s) 
    desync=$OPTARG
    ;;
  g) 
    galera_info=$OPTARG
    ;;
  t) 
    stream_host=$OPTARG
    ;;
  x) 
    echo "options are "
    echo "   -c <#> to enable --compress and pass --compress-threads=n "
    echo "   -h to set --history "
    echo "   -d <directory> to set backup directory as ${backup_root}/<your name> "
    echo "   -p <#> to override $parallel and set to --parallel=n supplied by you"
    echo "   -k <#> to override $keep and set to --keep=n supplied by you"
    echo "   -r issues the reset changed_page_bitmaps after the backup"
    echo "   -g adds --galera-info to backup invocation"
    echo "   -s <#> makes the percona node go into desync mode by setting global wsrep_desync=ON and waits <#> minutes (not seconds) "
    echo "          before actually starting the backup and after completion of the backup waits the same time before taking"
    echo "          the node out of desync mode.  If you don't want sleep but do want desync mode specify zero for minutes."
    echo "   -t use the xbstream option to send this backup to a remote host -t <hostname> hostname must be a fqdn or ip address.  You must verify that you can ssh to this "
    echo "          remote host using ssh keys with no prompt for password.  If this option is specified the -c option applies to "
    echo "          the xbstream compression.  If -p is specified (or defaults) the threads apply to both innobackup and xbstream."
    echo "          Make sure the named directory exists on the remote host; we do not create any directory except the new "
    echo "          named backup directory; so /backup/percona must exist and we will create the xtrabkupxxx directory."
    echo "          The backup LOGFILE will be copied to the remote host after the backup completes."
    exit 
  esac
done

# tell the caller our options
do_log "svn version=$SVN_VERSION"
do_log "history=$history"
do_log "compress option=$compress"
do_log "xbkup_dir=$xbkup_dir"
do_log "parallel=$parallel"
do_log "keep=$keep"
do_log "reset_bitmaps=$reset_bitmaps"
do_log "desync=$desync"
do_log "stream_host=$stream_host"
do_log "galara_info=$galara_galara_info"


# if -t flag is specified then test remote access and abort if we can't get to the remote host
if [ "x$stream_host" != "x" ]; then
	ssh_error=`ssh -q -o ConnectTimeout=10 $stream_host uptime`
	ssh_rc=`echo $?`
	if [ "$ssh_rc" -gt "0" ]; then
		do_log "ERROR ssh to remote streaming host=$stream_host has failed. "
		do_log "returned error code=$ssh_rc"
		do_log "returned error message=$ssh_error"
		do_log "aborting the backup" 
		do_log "check your ssh keys and make sure you can ssh without password from $HOST to $stream_host."
  		subj="Percona backup FAILED on $HOST"
  		send_email "$MESSAGE1" "$subj"
		exit 1
	else 
		do_log "successful ssh connection to $stream_host"
	fi
fi


# remove old backups either remote or both remote and local 
# for remote stream we execute a remote script to clean out old backups otherwise we do it locally
if [ "x$stream_host" != "x" ]; then
	do_log "starting remote call to remove_old_backups.sh on $stream_host"
	# call the removal script on the target
	ssh_error=`ssh -q -o ConnectTimeout=10 $stream_host /backup/scripts/remove_old_backups.sh $keep $backup_root `
	ssh_rc=`echo $?`
	if [ "$ssh_rc" -gt "0" ]; then
		do_log "ERROR remote cleanup of old backups failed.  "
		do_log "refer to /tmp/remove_old_backups.log on $stream_host "
		do_log "we do not continue to avoid filling the /backup directory"
		subj="Percona backup FAILED on $HOST "
  		send_email "$MESSAGE1" "$subj"
		exit 1
	else 
		do_log "successful call to remove_old_backups.sh on $stream_host"
	fi
fi
	
# meanwhile it does no harm to clean up our local host as well
cd $backup_root
do_log "cleaning out old backups (local host)" 
while [ `ls | wc -l` -gt $keep ]
do
	x_dir=`ls -c1t | tail -1`
 	do_log "removing $x_dir"
  	rm -rf $x_dir
done


# get the password to the server using backup account
do_log "getting backup password"
DWP=`zgrep BKUPWD /MYSIDS/mysql/dbpwdz | cut -d= -f2`


# now create a local .my.cnf file with login information for xtrabckup to use. 
rm -f $dflts
touch $dflts
chmod 600 $dflts

echo "[client]" > $dflts
echo "user=mbackup" >> $dflts
echo "password=$DWP" >> $dflts
echo "socket=/var/lib/mysql/mysql.sock" >> $dflts

# make sure the config file is working
mysql --login-path=root -e "show databases" > /dev/null;
if [ $? -eq 1 ];then
  do_log "connect to MySQL failed. Cannot continue. Aborting."
  rm $dflts
  send_email "$HOST backup failed cannot connect to mysql" "$HOST backup failed cannot connect to mysql"
  exit
fi

# determine if we are dealing with a cluster or single instance db
db_status=`mysql --login-path=root -e "status"  `
if [[ $db_status == *"Cluster"* ]]; then
	cluster=1
	do_log "Presume this is a cluster"
else
	cluster=0
	do_log "Presume this is not a cluster.  All cluster related options are ignored."
fi

if [ $cluster -eq "1" ]; then
	# show incomming transaction queue depth
	queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
	do_log "queue before any activity: $queue"

	# if desync requested then we set the node to desync mode and then we wait for specified minutes 
	# to let any connections age out. (it may not be necessary to do this for all applications.)
	if [[ "$desync" -ge "0" ]]; then
		do_log "desync mode requested." 
        	connections=`mysql --login-path=root -e 'show processlist' |wc -l`
		do_log "connections before desync=$connections"
		mysql --login-path=root -e "set global wsrep_desync=ON" >> $LOGFILE 2>&1
		do_log "desync mode enabled." 
	fi

	# now we sleep if they asked us to.
	if [ "$desync" -gt "0" ]; then
		desync_seconds=`expr $desync \* 60`	# figure out seconds to sleep
		do_log "desync mode sleep requested for $desync minutes ($desync_seconds seconds)."
		sleep $desync_seconds
		do_log "waking from sleep. beginning backup"
        	connections=`mysql --login-path=root -e 'show processlist' |wc -l`
		do_log "connections after desync sleep=$connections"
		queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
		do_log "queue after desync sleep: $queue"
			
	else 
		do_log "no sleep requested following desync mode setting"
	fi

	# check if any writesets are pending and see how many.
	queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
	do_log "queue before starting backup: $queue"

fi

# now we do the actual backup.  it took a while to get here.
START_DATE=`date +"%C%y-%m-%d %T"`
BACKUP_TYPE="XtraBackup"
do_log "##### Starting innobackupex on $HOST     date:$DATE  #######" 

if [ "x$stream_host" != "x" ]; then 	# stream backup
	# for some reason I cannot get a command in a varilable to work, so the command is replicated on the line below and executed. 
	do_log "creating $xbkup_dir on $stream_host"
	ssh -q $stream_host mkdir -p $xbkup_dir		# unlike a local backup we have to create the remote directory. 
	# this is block code { and } to force all output to our logfile as both innobackupex and stream generate output I cannot capture due to the pipe between the two function    uugh
	{
		innobackupex  $parallel $compress $galara_info  --no-timestamp --stream=xbstream ./  | ssh $stream_host xbstream --extract --directory=$xbkup_dir --verbose  
		BACKUP_RET=$?				# get our return code 
	} >> $LOGFILE 2>&1
else
	# regular non streamed backup
	{
		innobackupex $history $parallel $compress $galera_info --no-timestamp $xbkup_dir 
		BACKUP_RET=$?				# get our return code 
	} >> $LOGFILE 2>&1
fi
do_log "return code from backup=$BACKUP_RET"


if [ $BACKUP_RET == 0 ];then
  do_log "backup SUCCESSFUL" 
  echo "backup SUCCESSFUL"    # also send to any redirect from the job
else
  do_log "**** Percona backup was NOT SUCCESSFUL on $HOST ****" 
  subj="Percona backup FAILED on $HOST"
  send_email "$MESSAGE1" "$subj"
fi



# clear the change_page_bitmaps if requested
if [ $reset_bitmaps == 1 ];then
	do_log "reset of changed_page_bitmaps requested"
	mysql --login-path=root -e 'reset changed_page_bitmaps'  >> $LOGFILE 2>&1
fi

cp $cnf $xbkup_dir

END_DATE=`date +"%C%y-%m-%d %T"`
if [ "x$stream_host" != "x" ]; then 	# stream backup
	BACKUP_SIZE=`ssh -q $stream_host du -ks "$xbkup_dir" | cut -f1 `
else
	BACKUP_SIZE=$(du -ks "$xbkup_dir" | cut -f1)
fi
do_log "backup size is $BACKUP_SIZE"

do_log "recording backup state in database"

attrstr="{
  \"backup_start\":[\"${START_DATE}\"],
  \"backup_end\":[\"${END_DATE}\"],
  \"backup_size\":[${BACKUP_SIZE}],
  \"backup_type\":[\"${BACKUP_TYPE}\"],
  \"backup_server\":[\"${HOST}\"],
  \"errno\":[${BACKUP_RET}],
  \"backup_name\":[\"${xbkup_dir}\"],
  \"active\":[\"Y\"],
  \"backup_script\":[\"${SVN_VERSION}\"]
}";

mysql --login-path=repository -hite-dsb-mysql-mgmt-1.uspto.gov -e"call dbmgmt.add_attribute('"`uname -n`"', 'backup_report', '${attrstr}')" >> $LOGFILE 


if [ $cluster == 1 ]; then
	# report on wsrep_local_queue after backup. 
	queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
	do_log "queue after backup: $queue"

	# report on connections after backup for cluster
	connections=`mysql --login-path=root -e 'show processlist' |wc -l`
	do_log "connections after backup=$connections"

	# now we sleep for the same amount of time requested in desync to get wsre_local_recv_queue down to zero.  we hope!
	# an enhancement will be to actually check this instead of doing the sleep.
	# now we sleep if they asked us to.
	if [ "$desync" -gt "0" ]; then
		do_log "sleeping after backup $desync minutes."
		sleep $desync_seconds
		do_log "waking from sleep. "
		connections=`mysql --login-path=root -e 'show processlist' |wc -l`
		do_log "connections after post backup sleep=$connections"
		queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
		do_log "queue after post backup sleep: $queue"
	fi

	if [[ "$desync" -ge "0" ]]; then
		do_log "turning off desync mode." 
		mysql --login-path=root -e "set global wsrep_desync=OFF" >> $LOGFILE 2>&1 
		do_log "desync mode disabled." 
		connections=`mysql --login-path=root -e 'show processlist' |wc -l`
		do_log "connections after desync disabled=$connections"
		queue=`mysql --login-path=root -N -s -e 'show status like "wsrep_local_recv_queue"' `
		do_log "queue after desync disabled: $queue"
	fi
fi

do_log "end of backup job." 
rm -f $dflts
