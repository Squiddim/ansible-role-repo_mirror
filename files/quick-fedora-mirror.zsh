#!/bin/zsh
# {{ ansible_managed }}
# Simple script to grab the file list from Fedora and rsync everything that's
# changed since the last time we pulled.
#
# Originally written by Jason Tibbitts <tibbs@math.uh.edu> in 2016.
# Donated to the public domain.  If you require a statement of license, please
# consider this work to be licensed as "CC0 Universal", any version you choose.

# Variables in upper case are user configurables.

# ZSHISM? Turn on empty globs and globbing of dots
set -G -4
export LANG=C
# ZSHISM? newline for IFS.
IFS=$'\n'

# Declare globals
typeset -A tcounts   # Transfer counts

# Do this very early
starttime=$(date +%s)

# Debug output;
# Level 0: nothing except errors.
# Level 1: lvl0 unless there is a tranfer, and then basic info and times.
# Output goes to a file which may be spit out at the end of the run.
# Level >= 2: Always some info, output to the terminal.
db1 () {
    if (( VERBOSE >= 2 )); then
        echo $*
    elif (( VERBOSE >= 1 )); then
        echo $* >> $outfile
    fi
    # Otherwise output nothing....
}
db1f () { db1 $(printf $*); }

db2 () { (( VERBOSE >= 2 )) && echo $*}
db2f () { (( VERBOSE >= 2 )) && printf $*}
db3 () { (( VERBOSE >= 3 )) && echo '>>' $*}
db4 () { (( VERBOSE >= 4 )) && echo '>>>>' $*}
sep () { (( VERBOSE >= 2 )) && echo '============================================================'}

logwrite () {
    # Send logging info to the right place
    if [[ -n $LOGJOURNAL ]]; then
        echo $* >&3
    elif [[ -n $LOGFILE && -w $LOGFILE ]]; then
        echo $(date '+%b %d %T') $* >> $LOGFILE
    fi
}

logit () {
    # Basic logging function
    local item=$1
    shift
    local err=''
    [[ $item == 'E' ]] && err='ERR:'
    [[ $item == 'e' ]] && err='Err:'

    echo "$item  $err $@" >> $sessionlog

    if [[ $LOGITEMS =~ $item || $LOGITEMS =~ '@' ]]; then
        logwrite $err $*
    fi
    if (( VERBOSE >= 3 )); then
        db3 Log: $err $*
    fi

    # XXX Consider sending errors to stdout
    #if [[ -n $err ]]; then
    #    (>&2 echo $*)
    #fi
}

retcheck () {
    local ret=$1
    local prg=''
    [[ -n $2 ]] && prg="$2 "

    if [[ $ret -ne 0 ]]; then
        db1 "${prg}failed at $functrace[1]: with return $ret"
        logit E "${prg}call failed at $functrace[1]: with return $ret"
    fi
}

lock () {
    eval "exec 9>>$1"
    flock -n 9 && return 0
    return 1
}

save_state () {
    # Doing an mv here actually undoes the locking.  Could use cp instead.
    # Currently the unlocking is a good thing because it allows the checkin to
    # proceed without the next run waiting.  But this should be audited.
    if [[ -z $skiptimestamp ]]; then
        db2 Saving mirror time to $TIMEFILE
        if [[ -e $TIMEFILE ]]; then
            mv $TIMEFILE $TIMEFILE.prev
        fi
        echo LASTTIME=$starttime > $TIMEFILE

        if (( ? != 0 )); then
            (>&2 echo Problem saving timestamp file $TIMEFILE)
            logit E "Failed to update timestamp file"
            exit 1
        fi
    else
        db2 Skipping timestamp save.
    fi
}

append_state () {
    # Think about how to save extra state in the timestamp file or some
    # associated file.  Should we even do this?
    # Should this be saved to a separate status file instead?


    # Cannot rewrite the file or else the locking breaks.  Updating it should
    # be OK.
    # Save things in a format that can be sourced (VAR=value).
    # Repeated uses (VAR=value2) are OK and overwrite the previous value when the file is sourced.

    # What would use this?  A separate status program or some other monitor?
    #
    # Save data about the current transfer:
    # The current point in the process (
    # Counts
    # The current tempdir
    # Important transfer list files
    # The current rsync output file (for tailing and counting) since this is random.

}

cat_or_email () {
    # Output the contents of a file, either to stdout or in an email
    local file=$1

    if [[ ( ! -t 0 ) && ( -n "$EMAILDEST" ) ]]; then
        mail -E -s "$EMAILSUBJECT" "$EMAILDEST" < $file
    else
        cat $file
    fi
}

finish () {
    # Finish up, either dumping output to stdout or, if email is configured and
    # not running interactively, send email.
    #
    # Takes two optional arguments.  The first is the return value; the script
    # will exit with that value and will dump the output file to stdout if the
    # value is nonzero.  If the second is nonempty, the output will be
    # dumped/mailed regardless of the return value.
    local ret=$1
    local out=$2
    db1 "========================="
    db1 "Mirror finished: $(date) ($ret)"
    logit R "Run end; exiting $ret."
    if [[ $ret -gt 0 || -n $out ]]; then
        cat_or_email $outfile
    fi
    exit $ret
}

filter () {
    # Client-side file list filtering.
    if [[ -n $FILTEREXP ]]; then
        db4 filtering $1
        sed --in-place=-prefilter -r -e "\,$FILTEREXP,d" $1
    fi
}

hr_b () {
    # Produce human-readable byte counts
    # Yes, this has a bug at 1024EB
    typeset -F2 out

    if [[ $1 -lt 1024 ]]; then
        echo ${1}B
        return
    fi

    out=$(( $1 / 1024. ))
    for unit in KB MB GB TB PB EB; do
        (( $out < 1024 )) && break
        out=$(( out / 1024. ))
    done

    echo ${out}${unit}
}

hr_s () {
    # Produce human-readable second counts
    typeset -F2 out=$1

    if [[ $1 -lt 60 ]]; then
        echo ${1}s
        return
    fi

    out=$(( $1 / 60. ))
    if [[ $out -lt 60 ]]; then
        echo ${out}m
        return
    fi

    out=$(( $out / 60. ))
    echo ${out}h
}

parse_rsync_stats () {
    # Parse some of the statistics that rsync gives us.
    # Takes an rsync output log (stdout) as an argument.
    # No return value, but sill set several global variables:
    #   rsfilestransferred
    #   rsfilesize
    #   rstotalbytesreceived
    #   rstotalbytessent
    #   rsfilelistgentime
    #   rsfilelisttransfertime
    #   rstransferspeed
    #   rsspeedup
    # These will all be set unset if not present in the given log.
    #
    # Here's the full block of info that rsync provides:
    #
    # rsync[30399] (receiver) heap statistics:
    #   arena:         311296   (bytes from sbrk)
    #   ordblks:            2   (chunks not in use)
    #   smblks:             1
    #   hblks:              2   (chunks from mmap)
    #   hblkhd:        532480   (bytes from mmap)
    #   allmem:        843776   (bytes from sbrk + mmap)
    #   usmblks:            0
    #   fsmblks:           48
    #   uordblks:      178272   (bytes used)
    #   fordblks:      133024   (bytes free)
    #   keepcost:      131200   (bytes in releasable chunk)
    #
    # rsync[30394] (generator) heap statistics:
    #   arena:         311296   (bytes from sbrk)
    #   ordblks:            2   (chunks not in use)
    #   smblks:             1
    #   hblks:              2   (chunks from mmap)
    #   hblkhd:        532480   (bytes from mmap)
    #   allmem:        843776   (bytes from sbrk + mmap)
    #   usmblks:            0
    #   fsmblks:           48
    #   uordblks:      178208   (bytes used)
    #   fordblks:      133088   (bytes free)
    #   keepcost:      131200   (bytes in releasable chunk)
    #
    # Number of files: 11,140 (reg: 9,344, dir: 1,796)
    # Number of created files: 1,329 (reg: 1,327, dir: 2)
    # Number of deleted files: 0
    # Number of regular files transferred: 1,182
    # Total file size: 165,405,056,029 bytes
    # Total transferred file size: 3,615,178,247 bytes
    # Literal data: 3,229,943,512 bytes
    # Matched data: 385,234,735 bytes
    # File list size: 468,791
    # File list generation time: 0.217 seconds
    # File list transfer time: 0.000 seconds
    # Total bytes sent: 1,249,286
    # Total bytes received: 3,231,373,895
    #
    # sent 1,249,286 bytes  received 3,231,373,895 bytes  81,838,561.54 bytes/sec
    # total size is 165,405,056,029  speedup is 51.17

    local log=$1

    # Number of regular files transferred: 1
    unset rsfilestransferred
    rsfilestransferred=$(awk '/^Number of regular files transferred:/ {print $6; exit}' $log)

    # Total file size: 10,174,746 bytes
    unset rsfilesize
    rsfilesize=$(awk '/^Total file size: (.*) bytes/ {print $4; exit}' $log | sed -e 's/,//g')

    # Total bytes received: 2,425,728
    unset rstotalbytesreceived
    rstotalbytesreceived=$(awk '/^Total bytes received: (.*)/ {print $4; exit}' $log | sed -e 's/,//g')

    # Total bytes sent: 384,602
    unset rstotalbytessent
    rstotalbytessent=$(awk '/^Total bytes sent: (.*)/ {print $4; exit}' $log | sed -e 's/,//g')

    # File list generation time: 0.308 seconds
    unset rsfilelistgentime
    rsfilelistgentime=$(awk '/^File list generation time: (.*) seconds/ {print $5; exit}' $log)

    # File list transfer time: 0.000 seconds
    unset rsfilelisttransfertime
    rsfilelisttransfertime=$(awk '/^File list transfer time: (.*) seconds/ {print $5; exit}' $log)

    # sent 71 bytes  received 2,425,728 bytes  156,503.16 bytes/sec
    unset rstransferspeed
    rstransferspeed=$(awk '/^sent .* bytes .* received .* bytes (.*) bytes\/sec$/ {print $7; exit}' $log \
                      | sed -e 's/,//g')

    # total size is 10,174,746  speedup is 4.19
    unset rsspeedup
    rsspeedup=$(awk '/^total size is .* speedup is (.*)$/ {print $7; exit}' $log)
}

do_rsync () {
    # The main function to do a transfer
    # Accepts four options:
    #   1) The source repository
    #   2) The destination directory
    #   3) The list of files
    #   4) The name of an array containing additional rsync options
    #
    # This may sleep and retry when receiving specific errors.
    # Returns the rsync return code (where 0 indicates full success, but other
    # values may indicate a finished copy).

    local src=$1 dest=$2 files=$3 opts=$4
    local runcount=0
    local log=$(mktemp -p . rsync-out-XXXXXX.log)
    local errlog=$(mktemp -p . rsync-err-XXXXXX.log)
    local sleep rr rvbash rvzsh
    local rsyncto="--timeout=$RSYNCTIMEOUT"

    local -a verboseopts flopts allopts

    # These add to the default rsync verbosity
    (( VERBOSE >= 7 )) && verboseopts+=(--progress)
    (( VERBOSE >= 5 )) && verboseopts+=(-v)
    (( VERBOSE >= 4 )) && verboseopts+=(-v)

    # Usually we won't want to see this.
    (( VERBOSE <= 3 )) && verboseopts+=(--no-motd)

    flopts=("--files-from=$files")
    allopts=($rsyncto $RSYNCOPTS $verboseopts $flopts ${(P)opts} $src $dest)

    while true; do
        runcount=$(( runcount+1 ))
        # ZSHISM:  (P) flag to act on a variable by name.  Sadly, bash has
        # broken array handling.   bash 4.3 has local -n for this.  Older bash
        # needs hacks, or eval.  More info:
        # https://stackoverflow.com/questions/1063347/passing-arrays-as-parameters-in-bash
        # Or just use a freaking global.

        # We have to do this separately because you can't redirect to /dev/stderr when running under sudo.
        # ZSHISM Teeing both stderr and stdout while keeping the return code is
        # easy in zsh with multios but seems to be terribly difficult under bash.
        db3 Calling $RSYNC $allopts
        logit c calling $RSYNC $allopts
        # XXX background, then save $!, write it to the session log and wait on it.
        if (( VERBOSE >= 5 )); then
            $RSYNC $allopts 1>&1 2>&2 >> $log 2>> $errlog
        elif (( VERBOSE >= 2 )); then
            $RSYNC $allopts >> $log 2>&2 2>> $errlog
        else
            $RSYNC $allopts >> $log 2>> $errlog
        fi
        rr=$?

        # Check return values
        if (( rr == 0 )); then
            logit C rsync call completed succesfully with return $rr
            parse_rsync_stats $log
            return 0

        elif (( rr == 24 )); then
            # 24: Partial transfer due to vanished source files
            logit e "rsync says source files vanished."
            return $rr

        elif (( rr == 5 || rr == 10 || rr == 23 || rr == 30 || rr == 35 )); then
            # Most of these are retryable network issues
            #  5: Error starting client-server protocol
            # 10: Error in socket I/O
            # 30: Timeout in data send/receive
            # 35: Timeout waiting for daemon connection
            # 23: Partial transfer due to error
            #     (could be a file list problem)
            if [[ $rr -eq 23 && -f $errlog ]] ; then
                # See if it we tried to tranfer files that don't exist
                grep -q '^rsync: link_stat .* failed: No such file or directory (2)$' $errlog
                if (( ? == 0 )); then
                    logit e "Looks like the file list is outdated."
                    (>&2 echo "Looks like the file list is outdated.")
                    [[ -f $errlog ]] && (>&2 cat $errlog)
                    return $rr
                fi
            fi

            # It's not one of those special 23 errors, so we may retry.  First
            # see if we've already tried too many times.
            if (( runcount >= MAXRETRIES )); then
                logit E rsync from $REMOTE failed
                (>&2 echo "Could not sync from $REMOTE")
                [[ -f $errlog ]] && (>&2 cat $errlog)
                return $rr
            fi

            # Then sleep for a bit
            sleep=$(( 2 ** runcount ))
            logit e "rsync returned $rr (retryable), sleeping for $sleep"
            db2 rsync failed: sleeping for $sleep
            sleep $sleep
            continue
        fi

        # We only get here if we got a return we didn't expect
        logit E "rsync returned $rr, which was not expected."
        (>&2 echo "rsync returned $rr, which was not expected."
            [[ -f $errlog ]] && cat $errlog
        )
        return $rr
    done
}

usage () {
    cat <<END
Usage: quick-fedora-mirror [OPTION]

Update a local mirror of Fedora content via rsync and perform a mirrormanager
checkin.

Requires a configuration file; will search for this file in the following
locations:

  The path provided by -c/--config.
  /etc/quick-fedora-mirror/quick-fedora-mirror.conf
  /etc/quick-fedora-mirror.conf
  ~/.config/quick-fedora-mirror.conf
  quick-fedora-mirror.conf in the same directory as this script.
  quick-fedora-mirror.conf in the current directory.

Options:
  -a, --alwayscheck     Always compare local content with file lists, even if
                        file lists have not changed.
  -c, --config PATH     Specify configuration file instead of searching.
  -d LEVEL              Specify debugging level (0-9).
  -h, --help            This message.
  -n, --dry-run         Show what would be transferred, but do not actually
                        transfer, delete or check in.
  -N, --transfer-only   Download, but do not delete or check in.
  -t TIMESTAMP          Use TIMESTAMP (in seconds since epuch) as the last
                        mirror time.
  -T, --backdate TIME   Use TIME (a human readable date) as the last mirror
                        time.
END
  #--checkin-only        Force a mirrormanager checkin for all modules, but do
  #                      not transfer, delete or update the timestamp.
  #--dir-times           Update all directory times. (Not implemented.)
  #--refresh REGEX       Re-transfer all paths matching REGEX.  (Not implemented.)
}

parse_args () {
    # Process arguments, setting all sorts of globals
    while [[ $# > 0 ]]; do
        opt=$1
        case $opt in
            -a | --alwayscheck)
                alwayscheck=1
                ;;
            -c | --config)
                cfgfile=$2
                shift
                if [[ ! -r $cfgfile ]]; then
                    (>&2 echo Cannot read $cfgfile)
                    exit 1
                fi
                ;;
            -d) # Debugging
                verboseopt=$2
                shift
                ;;
            -h | --help)
                usage
                exit 1
                ;;
            -n | --dry-run)
                rsyncdryrun=1
                skipdelete=1
                skiptimestamp=1
                ;;
            -N | --transfer-only)
                skipdelete=1
                skiptimestamp=1
                ;;
            -t )
                backdate=$2
                alwayscheck=1
                shift
                ;;
            -T | --backdate)
                backdate=$(date -d "$2" +%s)
                alwayscheck=1
                shift
                ;;
            --checkin-only)
                skiptransfer=1
                skipdelete=1
                skiptimestamp=1
                forcecheckin=1
                ;;
            --dir-times)
                updatealldirtimes=1
                alwayscheck=1
                ;;
            --refresh)
                skipdelete=1
                skiptimestamp=1
                skipcheckin=1
                refreshpattern=$2
                shift
                ;;
            --dump-mm-checkin)
                # Just for the test suite; dump the raw payload to the given
                # filename with the module name appended.
                dumpmmcheckin=$2
                shift
                ;;
            --no-paranoia)
                # Don't backdate the last mirrortime
                noparanoia=1
                ;;
            *)
                (>&2 echo "Unrecognized argument.")
                exit 1
                ;;
        esac
        shift
    done
}

read_config () {
    # As a convenience, make sure $HOSTNAME is set
    if [[ -z "$HOSTNAME" ]]; then
        HOSTNAME=$(hostname)
    fi
    # Load up the configuration file from any of a number of locations
    local file
    for file in \
        $cfgfile \
        /etc/quick-fedora-mirror/quick-fedora-mirror.conf \
        /etc/quick-fedora-mirror.conf \
        ~/.config/quick-fedora-mirror.conf \
        $(dirname $0)/quick-fedora-mirror.conf \
        ./quick-fedora-mirror.conf; \
    do
        if [[ -r $file ]]; then
            source $file
            cfgfile=$file
            break
        fi
    done

    # Override some settings with previously parsed command-line options
    [[ -n $verboseopt ]] && VERBOSE=$verboseopt

    # Check that the required parameters were provided
    if [[ -z $DESTD ]]; then
        (>&2 echo "You must define DESTD in your configuration file ($cfgfile).")
    fi
    if [[ -z $TIMEFILE ]]; then
        (>&2 echo "You must define TIMEFILE in your configuration file ($cfgfile).")
    fi

    # Set some other general variables based on the value of provided
    # configuration settings
    [[ -z $CHECKIN_SITE ]] && skipcheckin=1
    [[ -z $MAXCHECKINRETRIES ]] && MAXCHECKINRETRIES=$MAXRETRIES
}

set_default_vars () {
    # Set various defaults before the configuration file is loaded.

    # Mapping from module names to directories under fedora-buffet
    # ZSHISM (initialize associative array)
    typeset -g -A MODULEMAPPING
    typeset -g -A MIRRORMANAGERMAPPING
    typeset -g -A MIRRORMANAGERMODULEMAPPING

    MODULEMAPPING=(
    fedora-alt          alt
    fedora-archive      archive
    fedora-enchilada    fedora
    fedora-epel         epel
    fedora-secondary    fedora-secondary
    )

    MIRRORMANAGERMAPPING=(
    fedora-alt          'fedora other'
    fedora-archive      'fedora archive'
    fedora-enchilada    'fedora linux'
    fedora-epel         'fedora epel'
    fedora-secondary    'fedora secondary arches'
    )

    # Mirrormanager has a weird prefix for "fedora-enchilada", so copy the
    # existing module mapping and alter it
    MIRRORMANAGERMODULEMAPPING=(${(kv)MODULEMAPPING})
    MIRRORMANAGERMODULEMAPPING[fedora-enchilada]="fedora/linux"

    # Default arguments; override in quick-fedora-mirror.conf
    VERBOSE=0
    LOGITEMS=aeElrR

    DESTD=
    TIMEFILE=

    CHECKIN_HOST=$(hostname)
    CURL=/usr/bin/curl
    FILELIST='fullfiletimelist-$mdir'
    EXTRAFILES=(fullfilelist imagelist-\$mdir)
    MIRRORMANAGER=https://admin.fedoraproject.org/mirrormanager/xmlrpc
    REMOTE=rsync://dl.fedoraproject.org
    RSYNC=/usr/bin/rsync
    RSYNCTIMEOUT=$((60 * 10))
    WARNDELAY=$((60 * 60 * 24))
    MAXRETRIES=10

    rsyncver=$(rsync --version | head -1 | awk '{print $3}')
    if [[ $rsyncver == 3.1.3 ]]; then
        # 3.1.3 has broken support for --preallocate and -S (--sparse) together
        RSYNCOPTS=(-aSH -f 'R .~tmp~' --stats --delay-updates --out-format='@ %i %10l  %n%L')
    elif [[ $rsyncver == 3.1* ]]; then
        RSYNCOPTS=(-aSH -f 'R .~tmp~' --stats --preallocate --delay-updates --out-format='@ %i %10l  %n%L')
    else
        RSYNCOPTS=(-aSH -f 'R .~tmp~' --stats --delay-updates --out-format='@ %i %10l  %n%L')
    fi

    MASTERMODULE=fedora-buffet
    MODULES=(fedora-enchilada fedora-epel)
}

check_file_list_version () {
    # Look at the file list to see if we can handle it
    #
    # Takes the file list name.
    # Returns 0 if we can handle it, 1 if we can't.
    local max_fl_version=3
    local fl=$1

    if [[ ! -f $fl ]]; then
        (>&2 echo "Cannot check file list \"$fl\".  Exiting.")
        exit 1
    fi

    local flversion=$(awk -F '\t' '/^\[Version/ {s=1; next} /^$/ {exit} {if (s) print $0}' < $fl)
    if [[ "$flversion" -le $max_fl_version ]]; then
        return
    fi

    # Either it is too new or we just can't parse it, so quit.
    (>&2 echo "File list from the mirror cannot be processed by this script.  Exiting.")
    exit 1
}

clean_all_transfer_temps () {
    # Delete temporary transfer files, but not any log files.
    # Be sure to add any extra generated temporaries here.
    # XXX Is it OK that this doesn't delete the file lists?  They will just get
    # copied over.
    rm -f *.old
    for i in ${(v)MODULEMAPPING} alldirs allfiles allfilesizes changedpaths \
        changes checksumfailed checksums deletedirs deletefiles flist \
        localdirs localfiles localfilesizes localfulllist master missingdirs \
        missingfiles newdirs newfiles staletmpdirs staletmpfiles \
        transferlist updatedfiles updatetimestamps; do
        rm -f $i-*
    done
}

clean_single_rsync_temp () {
    # Move a single rsync temporary file one directory up in the hierarchy
    #
    # rsync (at least version 3.2.3) appears to have some sort of bug which
    # causes it to fail to sync some files.  The working theory is that this
    # happens for small files which need timestamp changes.  It has been
    # observed for various .treeinfo (max 1550b), .discinfo (46b max) and a
    # README.html (479b) file.  When this manifests, a run will never complete
    # because rsync will fail to transfer the file and move it into the .~tmp~
    # directory, while q-f-m will move it back where it will tail to transfer
    # again.
    #
    # As a workaround for this, we simply delete "small" files (2kb) instead of
    # moving them.  Since the number of problem files appears to be small and
    # small files will transfer quickly, this should have little effect on the
    # overall transfer.
    local file=$1
    local size=$(stat -c '%s' $1)

    db3 "XXXXXX $file $size"

    if [[ -n $RSYNC_PARTIAL_DIR_BUG && "$size" -lt 2048 ]]; then
        logit A Deleting small previous download $file
        db3 Deleting small previous download: $file
        rm -f $file
    elif [[ ! -f ../$file ]]; then
        logit A Saving previous download $file
        db3 Saving previous download: $file
        mv $file ..
    elif [[ -n $RSYNC_PARTIAL_DIR_BUG ]]; then
        logit A Deleting partial download $file
        db3 Deleting partial download: $file
        rm -f $file
    fi
}

clean_stale_rsync_temps () {
    # Clean up temporaries left over from a previous aborted rsync run.
    local mod=$1

    db2 Possibly aborted rsync run.  Cleaning up.
    logit a "cleaning up previous aborted run: $(wc -l < staletmpfiles-$mod) file(s)."

    # Move the files in those tmpdirs a level up if a file with the same name
    # doesn't exist (and just delete the temp file if it does).  We don't
    # update the file lists because we want rsync to re-check those files and
    # possibly fix up the permissions.  The dirs will be cleaned up later.
    #
    # Note that this _may_ leave a few files around which should not be there,
    # and of course the content (and even partial content) will be visible
    # before it technically should be.  But that's better than nothing getting
    # done because aborted runs cause an endless buildup of partial transfers.
    # Extra files, if present, will of course be cleaned up at the next run and
    # rsync sill handle completing any partial downloads.
    #
    # XXX We could do better by comparing the stale files against the
    # to-be-fransferred list and only move things which are going to be
    # download in the run, but it's probably not worth it.
    for dir in $(cat staletmpdirs-$mod); do
        pushd "$DESTD/$dir"
        for file in *; do
            clean_single_rsync_temp $file
        done
        popd
        # It may be useful to clean up the temp directory, but in many cases
        # rsync will just recreate it and in any case it really should now be
        # empty.
        # rmdir $DESTD/$dir
    done
}

fetch_file_lists () {
    # Download the file list for each configred module
    # Will set the global variable "checksums" containing the checksum of the
    # file list of each module that exists on the client at the beginning of the transfer.

    local extra flname module rsyncreturn

    sep
    logit o Remote file list download start
    db2 Downloading file lists
    # ZSHISM (declare associative array)
    typeset -g -A checksums
    checksums=()
    for module in $MODULES; do
        # ZSHISM? (associative array indexing)
        moduledir=$MODULEMAPPING[$module]
        mkdir $moduledir
        flname=${FILELIST/'$mdir'/$moduledir}
        if [[ -f $DESTD/$moduledir/$flname ]]; then
            cp -p $DESTD/$moduledir/$flname $moduledir
            ln $moduledir/$flname $moduledir/$flname.old
            # ZSHISM (assign assoc. array value)
            checksums[$module]=$(sha1sum $DESTD/$moduledir/$flname | cut -d' ' -f1)
        fi

        echo $moduledir/$flname >> filelist-transferlist
    done

    extra=(--no-dirs --relative --compress)
    do_rsync $REMOTE/$MASTERMODULE/ . filelist-transferlist extra
    rsyncreturn=$?
    if [[ $rsyncreturn -ne 0 ]]; then
        (>&2 echo "rsync finished with nonzero exit status.\nCould not retrieve file lists.")
        logit E Aborting due to rsync failure while retrieving file lists
        finish 1
    fi

    # Log very basic stats
    logit s "File list download: $(hr_b $rstotalbytesreceived) received, $(hr_b $rstransferspeed)/s"

    # Check that we can handle the downloaded lists
    for module in $MODULES; do
        moduledir=$MODULEMAPPING[$module]
        flname=${FILELIST/'$mdir'/$moduledir}
        check_file_list_version $moduledir/$flname
    done

    # rsync won't transfer those files to the current directory, so move them and
    # clean up.
    mv */* .
    rmdir * 2> /dev/null
    logit o Remote file list download: end
}

checkin_build_inner_payload () {
    # Build the inner json payload
    # Takes the module name and the name of the output file to use
    local module=$1
    local mm=$2
    local checkinhost=$3

    local moduledir=$MIRRORMANAGERMODULEMAPPING[$module]
    local mmcheckin=$MIRRORMANAGERMAPPING[$module]

    cat >$mm <<EOF
{
    "$mmcheckin": {
        "dirtree": {
EOF

    # Output the data for each directory.  MM doesn't want the
    # directory name.
    for l in $(cat alldirs-$module); do
        echo "            \"${l/$moduledir\/}\": {}," >>$mm
    done

    # The data sent by report_mirror always includes a blank directory; add it
    # manually here which conveniently means we don't have to deal with the
    # trailing comma.  And after that, the various parameters mirrormanager
    # wants.
    cat >>$mm <<EOF
            "": {}
        },
        "enabled": "1"
    },
    "global": {
        "enabled": "1",
        "server": "$MIRRORMANAGER"
    },
    "host": {
        "enabled": "1",
        "name": "$checkinhost"
    },
    "site": {
        "enabled": "1",
        "name": "$CHECKIN_SITE",
        "password": "$CHECKIN_PASSWORD"
    },
    "stats": {},
    "version": 0
}
EOF
}

checkin_encode_inner_payload () {
    # Compress and encode the inner payload.
    # Takes the input and output filenames

    local in=$1
    local out=$2

    # The xmlrpc endpoint requires that the payload be bzip2 compressed
    bzip2 $mm

    # base64 encode
    base64 --wrap=0 $in.bz2 > $in.bz2.b64

    # change '+' to '-'  and '/' to '_'
    tr '+/' '-_' < $in.bz2.b64 > $out

    rm $in.bz2 $in.bz2.b64
}

checkin_build_outer_payload () {
    # Wrap the encoded payload in just the right xml
    # Takes input and output filenames

    local in=$1
    local out=$2

    cat >>$out <<EOF
<?xml version='1.0'?>
<methodCall>
<methodName>checkin</methodName>
<params>
<param>
EOF
    echo -n "<value><string>" >>$out

    cat <$in >>$out

    cat >>$out <<EOF
</string></value>
</param>
</params>
</methodCall>
EOF
}

checkin_upload_payload () {
    # Now actually upload the payload
    # We have to remove the Expect: header that curl sends but which mirrormanager cannot handle
    local payload=$1
    local module=$2
    local -a curlopts
    local curlret

    logit M "Making xmlrpc call for $module"
    curlopts=(--silent)
    curl --help | grep -q http1\.1
    (( ? == 0 )) && curlopts+=(--http1.1)
    (( VERBOSE >= 4 )) && curlopts=(--verbose)
    db3 "$CURL $curlopts -H \"Expect:\" -H \"Content-Type: text/xml\" --data @$mx $MIRRORMANAGER"
    $CURL $curlopts -H "Expect:" -H "Content-Type: text/xml" --data @$mx $MIRRORMANAGER > curl.out
    curlret=$?
    if [[ $curlret -ne 0 ]]; then
        logit e "Checkin failure: curl returned $curlret"
        (>&2 echo "Checkin failure: curl returned $curlret")
        return 2
    fi

    # Parse the output to see if we got any useful return
    # The sed call attempts to strip xml tags.  Easily fooled but we don't expect
    # any complicated return from mirrormanager.
    sed -e 's/<[^>]*>//g' curl.out > curl.noxml
    grep -q -i successful curl.noxml

    if [[ $? -ne 0 ]]; then
        db1 "Mirrormanager checkin for $module did not appear to succeed."
        logit e "Doesn't look like we got a good return from mirrormanager."
        logit e $(cat curl.noxml)
        return 1
    fi
    return 0
}

checkin_module () {
    # Perform the mirrormanager checkin for a particular module
    local module=$1

    local mm=mirrormanager-payload-$module
    local mx=mirrormanager-xmlrpc-$module
    local moduledir=$MODULEMAPPING[$module]

    if [[ ! -f alldirs-$module ]]; then
        # We were asked to check in a module that we hadn't previously
        # processed, which should not happen.
        logit E "Cannot perform checkin for $module; no directory list exists."
        return
    fi

    # Determine the "mirrormanager hostname" to use for this checkin.
    # Different modules can be set up under different "hosts" in mirrormanager,
    # even though these might all be on the same machine.  This works around
    # problems mirrormanager has when crawling machines which mirror
    # everything.
    # ZSHISM: This uses "(P)"; the equivalent in bash is "!".
    local checkinhost=$CHECKIN_HOST
    local hostspecificvar=CHECKIN_HOST_${module//-/_}
    if [[ -n ${(P)hostspecificvar} ]]; then
        checkinhost=${(P)hostspecificvar}
    fi

    db3 "Performing mirrormanager checkin for $module (in $moduledir) as $checkinhost"
    logit M "Processing $module (in $moduledir) as $checkinhost"

    # Construct the checkin payload
    checkin_build_inner_payload $module $mm $checkinhost
    checkin_encode_inner_payload $mm $mm.enc
    checkin_build_outer_payload $mm.enc $mx

    # For the test suite, just dump the checkin info and bail
    if [[ -n $dumpmmcheckin ]]; then
        cat $mx > $dumpmmcheckin-$module
        return
    fi

    # Try to check in until we've retried too often.
    local retries=1
    while true; do
        checkin_upload_payload $mx $module

        if [[ $? -eq 0 ]]; then
            break
        fi

        if (( retries >= MAXRETRIES )); then
            logit E "Could not complete checkin after $MAXCHECKINRETRIES tries."
            break
        fi

        logit e "Checkin attempt $retries failed.  Will retry."
        retries=$(( retries +1 ))
        sleep $(( 2*retries ))
    done

    logit M "Processing $module: end"
}

awk_extract_file_list () {
    local inf=$1
    local outf=$inf.flist
    [[ -n $2 ]] && outf=$2

    awk ' \
        /^\[Files/ {s=1;next}
        /^$/       {if (s==1) exit}
        s          {print}' \
        < $inf > $outf
    retcheck $? awk
}

awk_extract_paths_from_file_list_restricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    # We can just ignore the type and permissions completely
    awk -F '\t' "{print \"$mdir/\" \$4}" < $inf > $outf
    retcheck $? awk
}

awk_extract_paths_from_file_list_norestricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    awk -F '\t' " \
        { if (\$2 == \"d\" || \$2 == \"f\" || \$2 == \"l\") \
            print \"$mdir/\" \$4 \
        }" < $inf > $outf
    retcheck $? awk
}

awk_extract_newer_dirs_restricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    local last=0
    [[ -n $4 ]] && last=$4

    awk -F '\t' " \
        /\\[Files/ {s=1;next}
        /^\$/ {s=0;next}
        { if (s && \$1 >= $last \
            && (\$2 == \"d\" || \$2 == \"d-\" || \$2 == \"d*\")) \
            print \"$mdir/\" \$4 \
        }" \
        < $inf > $outf
    retcheck $? awk
}

awk_extract_newer_dirs_no_restricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    local last=0
    [[ -n $4 ]] && last=$4

     awk -F '\t' " \
        /\\[Files/ {s=1;next} \
        /^\$/ {s=0;next} \
        { if (s && \$1 >= $last \
            && (\$2 == \"d\")) \
            print \"$mdir/\" \$4 \
        }" \
        < $inf > $outf
    retcheck $? awk
}

awk_extract_newer_files_restricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    local last=0
    [[ -n $4 ]] && last=$4

    awk -F '\t' "/\\[Files/ {s=1;next} \
        /^\$/ {s=0;next} \
        {if (s && \$1 >= $last && \
            (\$2 == \"f\" || \$2 == \"f-\" || \$2 == \"f*\" \
            || \$2 == \"l\" || \$2 == \"l-\" || \$2 == \"l*\" \
            )) \
            print \"$mdir/\" \$4 \"\t\" \$3 \
        } \
        " $inf > $outf
    retcheck $? awk
}

awk_extract_newer_files_no_restricted () {
    local inf=$1
    local outf=$2
    local mdir=$3

    local last=0
    [[ -n $4 ]] && last=$4

    awk -F '\t' "/\\[Files/ {s=1;next} \
        /^\$/ {s=0;next} \
        {if (s && \$1 >= $last && \
            (\$2 == \"f\" \
            || \$2 == \"l\" \
            )) \
            print \"$mdir/\" \$4 \"\t\" \$3 \
        } \
        " $inf > $outf
    retcheck $? awk
}

process_file_list_diff () {
    # Extract and then diff the old and new file lists for a module
    # Creates changedfiles-$module file

    local fl=$1
    local mod=$2
    local mdir=$3

    local oldflist=flist-old-$mod
    local newflist=flist-new-$mod

    logit l "Generating database diff start: $mod"

    # Extract the file list part of old and new file lists.
    awk_extract_file_list $fl.old flist-old-$mod
    awk_extract_file_list $fl flist-new-$mod

    # sort each by path
    sort -t$'\t' -k4 $oldflist > $oldflist.sorted
    sort -t$'\t' -k4 $newflist > $newflist.sorted

    # compute the changes
    diff --changed-group-format='%>' --unchanged-group-format='' $oldflist.sorted $newflist.sorted > changes-$mod

    # Extract path from changes
    if [[ -n $PREBITFLIP ]]; then
        awk_extract_paths_from_file_list_restricted changes-$mod changedpaths-$mod $mdir
    else
        awk_extract_paths_from_file_list_norestricted changes-$mod changedpaths-$mod $mdir
    fi

    # We must filter here so that files we don't want to transfer won't appear
    # to have changed.
    filter changedpaths-$mod

    logit l "Generating database diff end: $mod"
}

compute_file_list_stats () {
    # Calculate and log counts of the various generated lists
    local mod=$1
    local -a stats
    stats=(allfiles alldirs newfiles newdirs changedpaths localfiles \
        localdirs deletefiles deletedirs missingfiles missingdirs \
        updatedfiles updatetimestamps checksumfailed)

    for i in stats; do
        counts[$i]=0
        [[ -f $i-$mod ]] && counts[$i]=$(wc -l < $i-$mod)
    done

    counts[totaltransfer]=$(wc -l transferlist-$mod)

    # Until the rest of the code is fixed up
    counts[extrafiles]=$counts[deletefiles]
    counts[extradirs]=$counts[deletedirs]
    counts[sizechanged]=$counts[updatedfiles]
    counts[allserverfiles]=$counts[allfiles]
    counts[allserverdirs]=$counts[alldirs]
    counts[newserverfiles]=$counts[newfiles]
    counts[newserverdirs]=$counts[newdirs]

    # Previously these two were printed before generating the local file lists
    db2f "Total on server:       %7d files, %4d dirs.\n" $cntallserverfiles $cntallserverdirs
    db2f "New on server:         %7d files, %4d dirs.\n" $cntnewserverfiles $cntnewserverdirs

    db2f "Total on client:       %7d files, %4d dirs.\n" $counts[localfiles $counts[localdirs]
    db2f "Not present on server: %7d files, %4d dirs.\n" $counts[extrafiles] $counts[extradirs]
    db2f "Missing on client:     %7d files, %4d dirs.\n" $counts[missingfiles] $counts[missingdirs]
    db2f "Size Changed:          %7d files.\n" $counts[sizechanged]
    db2f "Timestamps to restore: %7d files.\n" $counts[updatetimestamps]
    db2f "Checksum Failed:       %7d files.\n" $counts[checksumfailed]
    db2f "Filelist changes:      %7d paths.\n" $counts[changedpaths]
    db2f "Total to transfer:     %7d paths.\n" $counts[totaltransfer]

    logit L "Counts for $mod: Svr:$counts[allserverfiles]/$counts[allserverdirs] Loc:$counts[localfiles]/$counts[localdirs] Diff:$counts[changedpaths] New:$counts[newserverfiles]/$counts[newserverdirs] Xtra:$counts[extrafiles]/$counts[extradirs] Miss:$counts[missingfiles]/$counts[missingdirs] Size:$counts[sizechanged] Csum:$counts[checksumfailed] Dtim:$counts[updatetimestamps]"

}

generate_local_file_list () {
    # Generate lists of what the client has.
    local mod=$1
    local mdir=$2

    db3 Generating local file/dir list
    logit l "Generating local file list start: $mod"

    # Traverse the filesystem only once
    pushd $DESTD
    find $mdir/* -printf '%y\t%p\t%s\n' > $tempd/localfulllist-$mod
    popd

    # Now extract file and dir lists from that
    awk -F '\t' '{if ($1 == "d") {print $2}}' < localfulllist-$mod > localdirs-$mod
    awk -F '\t' '{if ($1 == "f" || $1 == "l") {print $2}}' < localfulllist-$mod > localfiles-$mod
    awk -F '\t' '{if ($1 == "f" || $1 == "l") {print $2 "\t" $3}}' < localfulllist-$mod > localfilesizes-$mod

    # Look for stray .~tmp~ dirs
    if [[ -z $NORSYNCRECOVERY ]]; then
        grep '\.~tmp~' localdirs-$mod > staletmpdirs-$mod
        grep '\.~tmp~' localfiles-$mod > staletmpfiles-$mod
    fi

    logit l "Generating local file list end: $mod"
}

process_local_file_list () {
    # Compare what the client has to what the server has, and generate more
    # lists based on that.
    # Generates the fillowing file lists:
    #     deletefiles-$module
    #     deletedirs-$module
    #     updatetimestamps-$module
    #     missingfiles-$module
    #     missingdirs-$module
    #     updatedfiles-$module
    #     checksumfailed-$module

    # XXX Don't do any master transferlist manipulation here.
    local mod=$1
    local mdir=$2

    # Find files on the client which don't exist on the server
    sort allfiles-$mod allfiles-$mod localfiles-$mod \
        | uniq -u  > deletefiles-$mod
    remove_filelists_from_file deletefiles-$mod $mdir

    # Find dirs on the client which don't exist on the server
    sort alldirs-$mod alldirs-$mod localdirs-$mod \
        | uniq -u > deletedirs-$mod

    # Extract dirnames of every file and dir in the delete lists, and all of their parents.
    if [[ -n $updatealldirtimes ]]; then
        echo $mdir > updatetimestamps-$mod
        cat alldirs-$mod >> updatetimestamps-$mod
    else
        awk '{dn($0)} function dn(p) { while (sub(/\/[^\/]*\]?$/, "", p)) print p }' \
            deletefiles-$mod deletedirs-$mod \
            | sort -u > updatetimestamps-$mod
    fi

    # Find files on the server which are missing on the client
    sort localfiles-$mod localfiles-$mod allfiles-$mod \
        | uniq -u > missingfiles-$mod

    # Find dirs on the server which are missing on the client
    sort localdirs-$mod localdirs-$mod alldirs-$mod \
        | uniq -u > missingdirs-$mod

    # Find files which have changed size
    sort allfilesizes-$mod localfilesizes-$mod \
        | uniq -u | awk -F '\t' '{print $1}' \
        | uniq -d > updatedfiles-$mod

    # Extract and verify checksums
    awk -F '\t' "/^\[Checksums/ {s=1; next} /^$/ {s=0; next} {if (s) print \$1 \"  $mdir/\" \$2}" $fl > checksums-$mod
    pushd $DESTD > /dev/null 2>&1
    sha1sum --check --quiet $tempd/checksums-$mod 2> /dev/null \
        | grep -i 'failed$' \
        | awk -F: '{print $1}' > $tempd/checksumfailed-$mod
    popd > /dev/null 2>&1
}

process_remote_file_list () {
    # Extract various file and directory lists from the master file list
    #
    # This will also handle ignoring restricted or pre-bitflip content if
    # necessary.
    #
    # Will create the following files:
    #   allfilesizes-$module
    #   allfiles-$module
    #   alldirs-$module
    #   newdirs-$module

    local fl=$1
    local module=$2
    local moduledir=$3

    db3 Extracting file and directory lists for $module.

    if [[ -n $PREBITFLIP ]]; then
        db4 "Directories (pre-bitflip included)"
        awk_extract_newer_dirs_restricted $fl alldirs-$module $moduledir

        db4 "New dirs (pre-bitflip included)"
        awk_extract_newer_dirs_restricted $fl newdirs-$module $moduledir $LASTTIME

        db4 "Files (pre-bitflip included)"
        awk_extract_newer_files_restricted $fl allfilesizes-$module $moduledir

        db4 "New files (pre-bitflip included)"
        awk_extract_newer_files_restricted $fl newfilesizes-$module $moduledir $LASTTIME
    else
        # All dirs, unrestricted only
        db4 "Directories (pre-bitflip excluded)"
        awk_extract_newer_dirs_no_restricted $fl alldirs-$module $moduledir

        db4 "New dirs (pre-bitflip excluded)"
        awk_extract_newer_dirs_no_restricted $fl newdirs-$module $moduledir $LASTTIME

        db4 "Files (pre-bitflip excluded)"
        awk_extract_newer_files_no_restricted $fl allfilesizes-$module $moduledir

        db4 "New files (pre-bitflip excluded)"
        awk_extract_newer_files_no_restricted $fl newfilesizes-$module $moduledir $LASTTIME
    fi

    # Filter the lists if needed
    filter alldirs-$module
    filter newdirs-$module
    filter allfilesizes-$module
    filter newfilesizes-$module

    # Produce the file lists without sizes.
    awk -F '\t' '{print $1}' allfilesizes-$module > allfiles-$module; retcheck $? awk
    awk -F '\t' '{print $1}' newfilesizes-$module > newfiles-$module; retcheck $? awk
}

update_master_file_lists () {
    # Simply append various per-module lists to the master lists
    cat deletefiles-$module >> master-deletefiles
    cat deletedirs-$module >> master-deletedirs
    cat updatetimestamps-$module >> master-updatetimestamps
    cat missingfiles-$module >> transferlist-$module
    cat missingdirs-$module >> transferlist-$module
    cat updatedfiles-$module >> transferlist-$module
    cat checksumfailed-$module >> transferlist-$module
}

remove_filelists_from_file () {
    # Remove the file from $FILELIST and anything given by $EXTRAFILES.
    # Takes:
    #   file to modify
    #   directory of current module (for substituting $mdir)
    # Modifies the file directly
    # Calls egrep -v in a loop.  Generally this is called on files of no more
    # than a few thousand lines, so performance shouldn't be an issue.

    local f=$1
    local moduledir=$2
    local tmp=$f.rfff
    local fl

    for fl in $FILELIST $EXTRAFILES; do
        fl=${fl/'$mdir'/$moduledir}
        egrep -v "^[^/]*/$fl" $f > $tmp
        mv $tmp $f
    done

    rm -f $tmp
}

process_module () {
    # Determine what needs to be transferred and removed from a single module.
    #
    # Takes the name of the module to process, returns nothing.
    #
    # Sets the following globals:
    # changed_modules
    #
    # Will leave the following lists in the temporary dir for use by other
    # functions: (all of them; currently deletes nothing)
    #
    # May leave other files, but don't depend on them.
    #
    # The various status variables, for logging:
    #   cntallserverfiles/cntallserverdirs - total files/dirs on server.
    #   cntnewserverfiles/cntnewserverdirs - new files/dirs on server (since last mirror time)
    #   cntlocalfiles/cntlocaldirs - total files/dirs on client.
    #   cntextrafiles/cntextradirs - files/dirs on client but not server.
    #   cntmissingfiles/cntmissingdirs - files/dirs on server but not client.
    #   cntsizechanged - files where size differs between server/client.
    #   cntupdatetimestamps - dir timestamps to restore
    #   cntchecksumfailed - files where checksum differs between server/client.
    #   cntchangedpaths - count of all differences between file lists.

    local module=$1
    # ZSHISM? (associative array indexing)
    local moduledir=$MODULEMAPPING[$module]

    local fl=${FILELIST/'$mdir'/$moduledir}
    local cntallserverfiles cntallserverdirs cntnewserverfiles cntnewserverdirs
    local cntchangedpaths cntlocalfiles cntlocaldirs cntextrafiles cntextradirsi
    local cntmissingfiles cntmissingdirs cntsizechanged cntupdatetimestamps cntchecksumfailed
    local extra

    if [[ -z $alwayscheck && \
            -n $checksums[$module] && \
            $(sha1sum $fl | cut -d' ' -f1) == $checksums[$module] ]]; then
        logit N No change in file list for $module
        db2 No change in file list checksum.  Skipping $module.
        continue
    fi

    sep
    logit P Processing start: $module
    db2 Processing $module
    changed_modules+=$module

    # Make sure the list is complete.
    tail -2 $fl | grep -q '^\[End\]$'
    if (( ? != 0 )); then
        logit e "Invalid file list; skipping $module"
        (>&2 echo "No end marker.  Corrupted file list?"
        echo Skipping $module.)
        return
    fi

    process_remote_file_list $fl $module $moduledir

    cntallserverfiles=$(wc -l < allfiles-$module)
    cntallserverdirs=$(wc -l < alldirs-$module)
    db2f "Total on server:       %7d files, %4d dirs.\n" $cntallserverfiles $cntallserverdirs

    cntnewserverfiles=$(wc -l < newfiles-$module)
    cntnewserverdirs=$(wc -l < newdirs-$module)
    db2f "New on server:         %7d files, %4d dirs.\n" $cntnewserverfiles $cntnewserverdirs

    # Add extra files to the transfer list
    echo $moduledir/$fl >> newfiles-$module
    for extra in $EXTRAFILES; do
        extra=${extra/'$mdir'/$moduledir}
        echo $moduledir/$extra >> newfiles-$module
    done
    cat newfiles-$module >> transferlist-$module
    cat newdirs-$module >> transferlist-$module

    if [[ -d $DESTD/$moduledir ]]; then
        db3 Finding file list changes since last run
        process_file_list_diff $fl $module $moduledir
        cat changedpaths-$module >> transferlist-$module

        generate_local_file_list $module $moduledir

        if [[ -s staletmpdirs-$module ]]; then
            clean_stale_rsync_temps $module
        fi

        # Find files on the client which don't exist on the server
        process_local_file_list $module $moduledir
        update_master_file_lists $module

        # Count some things we want to use for stats later.
        cntchangedpaths=$(wc -l < changedpaths-$module)
        cntlocalfiles=$(wc -l < localfiles-$module)
        cntlocaldirs=$(wc -l < localdirs-$module)
        cntextrafiles=$(wc -l < deletefiles-$module)
        cntextradirs=$(wc -l < deletedirs-$module)
        cntmissingfiles=$(wc -l < missingfiles-$module)
        cntmissingdirs=$(wc -l < missingdirs-$module)
        cntsizechanged=$(wc -l < updatedfiles-$module)
        cntupdatetimestamps=$(wc -l < updatetimestamps-$module)
        cntchecksumfailed=$(wc -l < checksumfailed-$module)

        db2f "Total on client:       %7d files, %4d dirs.\n" $cntlocalfiles $cntlocaldirs
        db2f "Not present on server: %7d files, %4d dirs.\n" $cntextrafiles $cntextradirs
        db2f "Missing on client:     %7d files, %4d dirs.\n" $cntmissingfiles $cntmissingdirs
        db2f "Size Changed:          %7d files.\n" $cntsizechanged
        db2f "Timestamps to restore: %7d files.\n" $cntupdatetimestamps
        db2f "Checksum Failed:       %7d files.\n" $cntchecksumfailed
        db2f "Filelist changes:      %7d paths.\n" $cntchangedpaths
    fi

    sort -u transferlist-$module >> transferlist-sorted-$module
    cat transferlist-sorted-$module >> master-transferlist
    local cnttotaltransfer=$(wc -l < transferlist-sorted-$module)
    db2f "Total to transfer:     %7d paths.\n" $cnttotaltransfer

    logit L "Counts for $module: Svr:$cntallserverfiles/$cntallserverdirs Loc:$cntlocalfiles/$cntlocaldirs Diff:$cntchangedpaths New:$cntnewserverfiles/$cntnewserverdirs Xtra:$cntextrafiles/$cntextradirs Miss:$cntmissingfiles/$cntmissingdirs Size:$cntsizechanged Csum:$cntchecksumfailed Dtim:$cntupdatetimestamps"
    logit P Processing end: $module
    db2 Finished processing $module.

    # Some basic info about the transfer.
    db1 Changes in $module: $cnttotaltransfer files/dirs
    if (( cnttotaltransfer <= 5 )); then
        for i in $(cat transferlist-sorted-$module); do
            db1 "    $i"
        done
    fi

    # XXX We should clean some things up at this point, but we also need some
    # files for the checkin later.
    # Should be able to delete all *-$module, except for the dirlists, to give
    # the current mirrormanager versions the things it needs.
    #if (( VERBOSE <= 4 )); then
    #    rm *-$module
    #fi
}


# Main program execution
# ======================
parse_args "$@"
set_default_vars
read_config

# XXX check_dependencies

# Paranoia; give us a few extra seconds.
[[ -z $noparanoia ]] && starttime=$(($starttime-5))

# Find the previous mirror time, and backdate if necessary
LASTTIME=0
if [[ -r $TIMEFILE ]]; then
    source $TIMEFILE
fi
if [[ -n $backdate ]]; then
    LASTTIME=$backdate
fi

# Make a temp dir and clean it up unless we're doing a lot of debugging
if [[ -z $TMPDIR ]]; then
    tempd=$(mktemp -d -t quick-mirror.XXXXXXXXXX)
else
    tempd=$(mktemp -d -p $TMPDIR -t quick-mirror.XXXXXXXXXX)
fi

if [[ $? -ne 0 ]]; then
    (>&2 echo "Creating temporary directory failed?")
    exit 1
fi
if (( VERBOSE <= 8 )); then
    trap "rm -rf $tempd" EXIT
fi

# Set up a FIFO for logging.  Just calling systemd-cat repeatedly just gives us
# a different PID every time, which is annoying.
if [[ -n $LOGJOURNAL ]]; then
    logfifo=$tempd/journal.fifo
    mkfifo $logfifo
    systemd-cat -t quick-fedora-mirror < $logfifo &
    exec 3>$logfifo
fi

outfile=$tempd/output
touch $outfile

sessionlog=$tempd/sessionlog
touch $sessionlog

touch $tempd/started-run

cd $tempd

# At this point we can acquire the lock
lock $TIMEFILE
if (( ? != 0 )); then
    db4 Could not acquire lock.
    logit k lock contention
    # Maybe we haven't been able to mirror for some time....
    delay=$(( starttime - LASTTIME ))
    if [[ -n $backdate || $LASTTIME -eq 0 ]]; then
        delay=0
    fi

    if (( delay > WARNDELAY )); then
        (>&2 echo No completed run since $(date -d @$LASTTIME ).)
        logit E No completed run since $(date -d @$LASTTIME ).
    fi
    exit 1
fi

db1 "Mirror starting: $(date)"
logit r Run start: cfg $cfgfile, tmp $tempd

if [[ -n $MIRRORBUFFET ]]; then
    # We want to mirror everything, so save the admin from listing the
    # individual modules.
    # ZSHISM (get keys from an associative array with (k))
    MODULES=(${(k)MODULEMAPPING})
    # BASHEQ MODULES=${!MODULEMAPPING[@]}
    # bash3 equivalent is terrible
fi

if (( VERBOSE >= 6 )); then
    echo Times:
    echo LASTTIME=$LASTTIME
    echo starttime=$starttime
    echo TIMEFILE=$TIMEFILE
    echo Dirs:
    echo tempd=$tempd
    echo DESTD=$DESTD
    echo Rsync:
    echo REMOTE=$REMOTE
    echo MASTERMODULE=$MASTERMODULE
    echo RSYNC=$RSYNC
    echo RSYNCOPTS=$RSYNCOPTS
    echo Modules:
    echo MODULES=$MODULES
    echo MODULEMAPPING=$MODULEMAPPING
    echo Misc:
    echo VERBOSE=$VERBOSE
fi

(( VERBOSE >= 8 )) && set -x

fetch_file_lists

logit p Processing start
changed_modules=()
for module in $MODULES; do
    process_module $module
done

if [[ ! -e master-transferlist ]]; then
    logit n No changes to synchronize
    db2 No changed files.
    finish 0
fi

if [[ -n $MIRRORBUFFET ]]; then
    echo DIRECTORY_SIZES.txt >> master-transferlist

    # If there's an rsync temp directory in the top level, delete it to work
    # around a potential rsync bug.
    if [[ -n $RSYNC_PARTIAL_DIR_BUG ]]; then
        rm -rf $DESTD/.~tmp~
    fi
fi

# The actual transfer
# ===================
sort -u master-transferlist > master-transferlist.sorted
linecount=$(wc -l < master-transferlist.sorted)
sep; sep
db2 Transferring $linecount files.
# XXX send total count to log as well

touch $tempd/started-transfer

# Now we have a list of everything which has changed recently in every module
# we want, pass that to rsync (non recursive mode!) and it should transfer just
# the changed files without having to pull the entire huge file list.
extra=()
if [[ -n $rsyncdryrun ]]; then
    extra+=(-n)
fi
do_rsync $REMOTE/$MASTERMODULE/ $DESTD master-transferlist.sorted extra
if (( ? != 0 )); then
    (>&2 echo "rsync failed; aborting run.\nWill not check in or delete anything.")
    logit "E Skipping further operations due to rsync failure."
    finish 1
fi

# Total downloaded file count, bytes received, transfer speed
logit s "stat: downloaded $rsfilestransferred files"
logit s "stat: received $(hr_b $rstotalbytesreceived)"
logit s "stat: transfer speed $(hr_b $rstransferspeed)/s"

# Everything we can extract from rsync
logit S "stat: sent $(hr_b $rstotalbytessent)"
logit S "stat: speedup: $rsspeedup"
logit S "stat: total size of transferred files: $(hr_b $rsfilesize)"
logit S "stat: file list gen time $(hr_s $rsfilelistgentime)"
logit S "stat: file list transfer time $(hr_s $rsfilelisttransfertime)"

db1 "========================="
db1 "Main transfer statistics:"
db1 "    Downloaded files: $rsfilestransferred"
db1 "    Total size of those files: $(hr_b $rsfilesize)"
db1 "    Received: $(hr_b $rstotalbytesreceived)"
db1 "    Sent: $(hr_b $rstotalbytessent)"
db1 "    Speedup: $rsspeedup"
db1 "    Transfer speed: $(hr_b $rstransferspeed)/s"
db1 "    File list generation time: $(hr_s $rsfilelistgentime)"
db1 "    File list transfer time: $(hr_s $rsfilelisttransfertime)"

# Local dir/file deletion
# =======================
if [[ -s master-deletedirs ]]; then
    linecount=$(wc -l < master-deletedirs)

    if [[ -n $skipdelete && $VERBOSE -ge 2 ]]; then
        logit d Directory deletion skipped
        echo "Not deleting  $linecount directories.  Delete list is:"
        cat master-deletedirs
        echo
    else
        logit d Directory deletion start: $linecount directories
        db2 Removing $linecount stale directories.
        for nuke in $(cat master-deletedirs); do
            if [[ -d "$DESTD/$nuke" ]]; then
                logit D Deleting directory $nuke
                db4 Removing $nuke
                rm -rf "$DESTD/$nuke"
                deletedsomething=1
            fi
        done
        logit d Directory deletion end
    fi
else
    db2 No stale directories to delete.
fi

if [[ -s master-deletefiles ]]; then
    linecount=$(wc -l < master-deletefiles)

    if [[ -n $skipdelete ]]; then
        logit d File deletion skipped
        echo Not deleting $linecount stale files.  Delete list is:
        cat master-deletefiles
        echo
    else
        logit d File deletion begin: $linecount files
        db2 Removing $linecount stale files.
        # xopts=()
        # (( VERBOSE >= 4 )) && xopts=(-t)
        tr '\n' '\0' < master-deletefiles \
            | (pushd $DESTD; xargs $xopts -0 rm -f ; popd)
        # for nuke in $(cat master-deletefiles); do
        #     logit D Deleting file $nuke
        #     rm -f "$DESTD/$nuke"
        # done
        deletedsomething=1
        logit d File deletion end
    fi
else
    db2 No stale files to delete.
fi

if [[ ( -n $KEEPDIRTIMES || -n $updatealldirtimes ) && -s master-updatetimestamps ]]; then
    extra=()
    if [[ -n $rsyncdryrun ]]; then
        extra+=(-n)
    fi
    logit d "Updating timestamps on $(wc -l < master-updatetimestamps) dirs"
    do_rsync $REMOTE/$MASTERMODULE/ $DESTD master-updatetimestamps extra
fi

# We've completed a run, so save the timestamp
save_state

# Mirrormanager Checkin and Callout
# =================================
# At this point we know that we had a clean run with no complaints from rsync,
# and as far as we're concerned the run is now complete and recorded.
#
# So for each module we mirrored, the filtered file list is correct.  This
# means that the alldirs-$module file is accurate and we can simply report its
# contents to mirrormanager.
if [[ -z $skipcheckin || -n $dumpmmcheckin ]]; then
    db2 Performing mirrormanager checkin
    logit m "mirrormanager checkin start"

    # Check in just the changed modules
    for module in $changed_modules; do
        checkin_module $module
    done

    logit m "mirrormanager checkin end"
fi
finish 0 yes
