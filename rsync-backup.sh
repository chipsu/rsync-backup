#!/bin/bash
#
# RSync backup script
#
# Use at your own risk!
#
# @todo rsh config, use arcfour for LAN only
# @todo fails silently of dst doesn't exist? (unmounted)
#

configDir=~/.rsync-backup
rsyncConfig=""
dryRun=1

while getopts ":rc:" opt; do
    case $opt in
    r)
        dryRun=0
        ;;
    c)
        configDir="$OPTARG"
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
    esac
done

if [[ $dryRun != 0 ]]; then
    rsyncConfig="$rsyncConfig --dry-run -v"
fi

BLACK='\E[30;47m'
RED='\E[31;47m'
GREEN='\E[32;47m'
YELLOW='\E[33;47m'
BLUE='\E[34;47m'
MAGENTA='\E[35;47m'
CYAN='\E[36;47m'
WHITE='\E[37;47m'

COUNT=0
LEVEL=0

cecho() {
	echo -e "$2$1\033[0m" >&$((0$3))
	tput sgr0
}

log() {
	echo -n $(date --rfc-3339=seconds --utc)
	if [ $LEVEL -gt 0 ]; then
		eval "printf '    %.0s' {1..$LEVEL}"
	fi
	echo " $@"
}

log_err() {
	local TEXT=$(log "***ERROR*** $@")
	cecho "$TEXT" $RED 2
}

log_warn() {
	local TEXT=$(log "***WARNING*** $@")
	cecho "$TEXT" $YELLOW
}

log_push() {
	LEVEL=$((LEVEL+1))
}

log_pop() {
	LEVEL=$((LEVEL-1))
}

backup_main() {
    [[ $UID != 0 ]] && {
        log_err "Run this script as root"
        exit 1
    }

    type rsync &>/dev/null || {
        log_err "rsync is not installed"
        exit 1
    }

    [[ ! -d "$configDir" ]] && {
        log_err "config_dir $configDir is does not exist"
        exit 1
    }

    log "Starting..."

    for configFile in "$configDir"/*.conf; do
        declare -A src
        src=()
        dst=()
        exclude=
        include=
        delete=0
        disable=0

        source "$configFile" || {
            log_err "Invalid configuration file $configFile"
            continue
        }

        if [[ $disable != 0 ]]; then
            continue
        fi

        # exclude include file
        if [[ $exclude == "" ]]; then
            exclude="$(basename "$configFile" .conf).exclude"
        fi

        if [[ ! -f "$exclude" ]]; then
            if [[ -f "$configDir/$exclude" ]]; then
                exclude="$configDir/$exclude"
            else
                log_err "Exclude file $exclude does not exist"
                continue
            fi
        fi

        # detect include file
        if [[ $include == "" ]]; then
            include="$(basename "$configFile" .conf).include"
        fi

        if [[ ! -f "$include" ]]; then
            if [[ -f "$configDir/$include" ]]; then
                include="$configDir/$include"
            else
                log_err "Include file $include does not exist"
                continue
            fi
        fi

        # loop destinations
        log "$(basename "$configFile")"
        log_push

        for dstPath in "${dst[@]}"; do
            for srcIndex in "${!src[@]}"; do
                source="${src[$srcIndex]}"
                target="$dstPath/$srcIndex"
                current="$target/current"
                #backup="$target/$(date +%Y%m%d-%H%M%S)"
                backup="../backup-$(date +%Y/%Y%m%d-%H%M%S)"

                #if [[ ! -d "$current" ]]; then
                #    mkdir -p "$current" || {
                #        log_err "Could not create directory $current"
                #        continue
                #    }
                #fi

                if [[ ! -d "$source" ]]; then
                    log_err "source '$source' does not exist, skipping"
                    continue
                fi

                find "$source" -mindepth 1 -print -quit | grep -q .

                if [[ $? != 0 ]]; then
                    log_err "source '$source' is empty, skipping"
                    continue
                fi

                log "$source => $target"
                log_push
                    # hack to create parent dir on remote...
                    tempDir="$(mktemp -d)"
                    rsync $rsyncConfig --rsh="ssh -c arcfour" -a --fake-super "$tempDir/" "$target"
                    rmdir "$tempDir"

                    # do it!
                    rsync $rsyncConfig --rsh="ssh -c arcfour" \
                        -rltD --fake-super --no-o --no-g --chmod=ug=rwX --force --ignore-errors --delete-excluded \
                        --exclude-from "$exclude" \
                        --include-from "$include" \
                        --exclude "*" --delete --backup --backup-dir "$backup" "$source" "$current"
                    if [[ $? == 0 ]]; then
                        log "Done"
                        if [[ $dryRun == 0 ]]; then
                            if [[ $delete -gt 0 ]]; then
                                log_warn "fixme: delete is not working for remote destinations"
                                # fixme, how do we do this on remote dst?
                                #find "$target" -mindepth 1 -maxdepth 1 -type d ! -name current -name "backup-*" -mtime +$delete -exec echo deleting old backup: {} \; -exec echo rm -rf {} \;
                            fi
                        fi
                    else
                        log_err "Fail. Result = $?"
                        status=1
                    fi
                log_pop
            done
        done

        log_pop
    done
}

backup_main

