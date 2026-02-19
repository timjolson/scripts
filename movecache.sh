#!/bin/bash
# Script to automate moving files from a `src` to `dest` based on usage % of `src` filesystem. Uses `rclone move` to
#       transfer the files and structure, then deletes empty directories from `src` location. `rclone move` is called with
#	--check-first as its only option (unless dryrun is true, then `--dry-run -v` are added).
# 
#	Optional (TODO) is rsync as a move method, and further option (TODO) of setting specific rsync options.
#	Default rsync options include as many attributes as available ( rsync -aSHAXWERm --delay-updates --preallocate --relative --remove-source-files )
#
# Args
#	`src` directory ( use basic syntax, absolute path, and end with '/' )
#	`dest` directory ( use basic syntax, absolute path, and end with '/' )
#	`trigger` percentage ( format is '90' = 90 percent )
#	`target` percentage ( format is '90' = 90 percent )
#   `exclude` pattern to exclude from the transfer
#   `precmd` command to run before beginning transfer
#   `postcmd` command to run after finishing transfer
#
# If the `src` filesystem usage % is greater than `trigger`, moves the oldest file from `src` to `dest`, 
#	maintaining the source directory structure. This repeats until either there are no files left to move
#	in `src` or `src` usage % is lower than `target`. After all transfers are complete, uses `find`
#	command to delete empty directories in the `src` folder.
#
# Logging
# 	-As a service (such as through systemd), logging is handled by the unit file.
# 	-Running the script directly, set `logtofile`=true. The log location is then built from the basename
# 		of the script, and goes in /var/log/{SCRIPTNAME}.log
logtofile=true

source /usr/local/bin/scripts/functions.sh

# Default values
declare -A DEFAULTS=(
    ["src"]=""
    ["dest"]=""
    ["exclude"]=" -path /lkjsadf84a7hjlisdjfsdiaj -prune "
    ["trigger"]="-98"
    ["target"]="-99"
    ["precmd"]=""
    ["postcmd"]=""
    ["dryrun"]=false
    ["batch"]=5
    ["debug"]=false
)

[ $# -ge 4 ] || { log "Usage $0 [--src <src>] [--dest <dest>] [--trigger <trigger percent>] [--target <target percent>] [--exclude <path_to_exclude_from_tar>] [--precmd <pre-transfer command>] [--postcmd <post-transfer command>] [--batch <integer size of batch>]"; exit 2; }
parse_args DEFAULTS "$@"

[ -z "${src}" ] && { log "Must provide a src directory"; exit 2;}
[ -z "${dest}" ] && { log "Must provide a dest directory"; exit 2;}
[ ! -d "${src}" ] && { log "Directory \"$src\" does not exist"; exit 2;}
[ ! -d "${dest}" ] && { log "Directory \"$dest\" does not exist"; exit 2;}

# Make sure relevant commands are available
# TODO: mv option
command -v /usr/bin/rclone >/dev/null 2>&1 || { log "Error: rclone command not found."; exit 127; }
# TODO: rsync option instead of rclone
# command -v /usr/bin/rsync >/dev/null 2>&1 || { log "Error: rsync command not found."; exit 127; }

transferflag=false
ran_precmd=false

function get_current_percentage(){
	df --output=pcent "${src}" | grep -v Use | cut -d'%' -f1 | rev | cut -d ' ' -f1 | rev
}
current=$(get_current_percentage)

# handle delta % instead of just trigger&target
if [[ ${trigger} -eq "-98" ]]; then
	# trigger was NOT provided
	if [[ ${target} -ne -99 ]]; then
		# target was provided
		delta=$(( target * ((target<0) - (target>0)) ))
		target=$(( current + delta ))
		log "Source at ${src} using ${current}%. Drawing down by $delta% --> $target%."
		trigger=${current}
	else
		# target was NOT provided
		# default values will move everything
		log "No trigger or target provided, will move all available files."
	fi
else
	# trigger WAS provided
	if [[ ${target} -eq "-98" ]]; then
		# target was NOT provided
		log "No target provided, will move all available files if applicable."
	else
		# target WAS provided
		log "Source at ${src} using ${current}%. Goal is ${trigger}% --> ${target}%."
	fi
fi


if [ ${current} -ge ${trigger} ]
then

	while [ $(get_current_percentage) -gt ${target} ]
	do
		log "Disk percentage $(get_current_percentage)%>$target%."
#		FILELIST=$(trap "" SIGPIPE; find "${src}" -not \( -path "${exclude}" -prune \) -type f -printf '%A@ %P\n' | sort)
                [[ "$debug" = true ]] && log "find command is:"
                [[ "$debug" = true ]] && log "find \"${src}\" \( ${exclude} \) -prune -o -type f -printf '%T@ %P\n' | sort"
		FILELIST=$(trap "" SIGPIPE; find "${src}" \( ${exclude} \) -prune -o -type f -printf '%T@ %P\n' | sort)
		[[ "$debug" = true ]] && log "Sample of FILELIST"
		[[ "$debug" = true ]] && log "$(printf "%s\n" "$FILELIST" | head -n 3)"
		
		if [[ -z "$FILELIST" ]]; then
		    log "No files found to move"
		    break
		fi
        
		declare -a fileArray
		fileArray=()
		
		# Read each line into the array
        while IFS= read -r line; do
            fileArray+=("$line")
        done <<< "$FILELIST"
        [[ "$debug" = true ]] && log "fileArray sample \"${fileArray[@]:0:2}\""
        log "Found ${#fileArray[@]} eligible files."
        
        if [ ${#fileArray[@]} -eq 0 ]; then
            log "No files available to move."
            break
        else
            # run stopcmd if it has not been run and it is set
            if [[ "$ran_precmd" = false && -n precmd && "$dryrun" = false ]]; then
                log "Running precmd \"$precmd\""
                output=$(bash -c "$precmd" 2>&1)
                [ ! -z "$output" ] && log "precmd output: $output"
                ran_precmd=true
            fi
        fi
        
        # while disk usage is right and there are files left, move a batch of files
        log "Starting batch move of up to $batch files."
        count=0
	    while [[ $(get_current_percentage) -ge ${target} && ${#fileArray[@]} -gt 0 && $count -lt $batch ]]
	    do
	        count=$((count + 1))
	        
            FILE=$(echo "${fileArray[0]}" |  cut -d' ' -f2-)
            [[ "$debug" = true ]] && log "FILE= $FILE"
            
            # Check that FILE is not empty
		    [[ -z $FILE ]] && { log "File string is empty: $FILE"; exit 1; }
		    [[ -n $FILE ]] || { log "File string contains nothing: $FILE"; exit 1; }
            
		    file_sub_dir=${FILE%/*}
		    file_src_path=${src}/${FILE}
		    
		    if [[ "$file_sub_dir" == "$FILE" ]]; then
		        [[ "$debug" = true ]] && log "Standalone file \"$FILE\""
		        file_sub_dir=""
		        dest_dir=${dest}/
		    else
		        dest_dir=${dest}/${file_sub_dir}/
		    fi
		    
		    # Check that FILE is a file
		    [[ -f $file_src_path ]] || { log "Not a file: \"$file_src_path\"."; exit 2; }
		    # Check that FILE is accessible
		    [[ -r $file_src_path ]] || { log "File \"$file_src_path\" is inaccessible."; exit 7; }
		    
		    if [ "$dryrun" = true ]
		    then
			    log "Dry-running moving \"$file_src_path\" to \"$dest_dir\""
			    #rsync -naSHAXWERm --delay-updates --preallocate --relative --remove-source-files "${src}/./${FILE}" "${dest}/" | log
			    rclone move "${file_src_path}" "${dest_dir}" --check-first --dry-run -v | log
			    stat=${PIPESTATUS[0]}
			    [ $stat -ne 0 ] && { log "Failed to move file. Exit code $stat"; exit $stat; }
			    break
		    else
			    # do real file transfer and do not exit loop
			    #rsync -aSHAXWERm --delay-updates --preallocate --relative --remove-source-files "${src}/./${FILE}" "${dest}/" | log
			    log "Moving \"$file_src_path\" to \"$dest_dir\""
                            rclone move "${file_src_path}" "${dest_dir}" --check-first
			    stat=${PIPESTATUS[0]}
			    [ $stat -ne 0 ] && { log "Failed to move file. Exit code $stat."; exit $stat; }
			    transferflag=true
		    fi
            
            if [ ${#fileArray[@]} -gt 0 ]; then 
                fileArray=("${fileArray[@]:1}")
                [[ "$debug" = true ]] && log "Going to next file."
            else
                [[ "$debug" = true ]] && log "Finished batch."
                break
            fi
        done # finish batch of file moves

        if [ "$dryrun" = true ]; then
            log "Broke batch loop after first file."
            break
        fi

    done # finish all file move loops (usage % loop)
fi # finish usage IF


if [ "$transferflag" = true ]
then
	# delete empty directories after transfer (rsync does not do this)
	log "Deleting empty directories in \"$src\"."
	( find "${src}" -mindepth 1 -type d -empty -delete && log 'Done.' ) || log "Error deleting empty directories."
	log "Source at \"$src\" using $(get_current_percentage)%."
fi

# run postcmd
if [[ -n postcmd && "$ran_precmd" = true && "$dryrun" = false ]]; then
    log "Running postcmd: \"$postcmd\""
    output=$(bash -c "$postcmd" 2>&1)
    [ ! -z "$output" ] && log "Postcmd output: \"$output\""
fi

log "Done."

exit 0

