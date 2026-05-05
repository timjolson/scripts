#!/bin/bash
# Script to automate moving files from a `src` to `dest` based on usage % of `src` filesystem. Uses `rclone move` to
#       transfer the files and structure, then deletes empty directories from `src` location. `rclone move` is called with
#	--check-first as its only option (unless dryrun is true, then `--dry-run -v` are added). Files are moved in order of 
#    oldest modification time first, until either the `src` usage % is below `target`, there are no more files to move,
#	or the destination runs out of space.
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
#   `precmd` command to run before beginning transfer (does not execute when dryrun is true or no files are to be moved)
#   `postcmd` command to run after finishing transfer (does not execute when dryrun is true or no files were moved)
#	`dryrun` boolean to indicate whether to do a dry run (true) or real run (false)
#	`batch` integer number of files to move per batch (10) larger batches are more efficient for large number of files
#	`debug` boolean to indicate whether to log debug information (true) or not (false)
#	`min-dest-space` minimum free space required on destination to proceed with transfer.
#		Bare numbers are interpreted as bytes. Suffixes `B`, `KB`, `MB`, `GB`, and percentages
#		like `15%` are also accepted. (default `0` = 0 bytes)
#   `transferuser` user to run rclone move command as, if different from the script runner (default is the script runner's user)
#
# If the `src` filesystem usage % is greater than `trigger`, moves the oldest file from `src` to `dest`, 
#	maintaining the source directory structure. This repeats until either there are no files left to move
#	in `src` or `src` usage % is lower than `target`. After all transfers are complete, uses `find`
#	command to delete empty directories in the `src` folder.
#
# Shutdown behavior:
# 	-On `SIGTERM`/`SIGHUP`, the script records the in-progress transfer context, runs cleanup,
# 		and then runs `postcmd` before exiting with the signal-derived status.
# 	-On `SIGINT`, the script performs the same cleanup but skips `postcmd`, treating it as an
# 		interactive abort rather than a managed service stop.
#
# Destination space handling:
# 	-The script checks destination free space before each batch.
# 	-If `rclone` later fails because the destination fills up during a transfer, the script marks
# 		that as an insufficient-space condition, stops further processing, runs finalization, and exits 28.
#	-`min_dest_space` accepts decimal units (`B`, `KB`, `MB`, `GB`) or `%` of the destination filesystem size.
#
# Exit Codes:
# 	0 - Success
# 	2 - Missing or invalid arguments
# 	28 - Insufficient destination space (pre-check or `rclone` write failure caused by destination exhaustion)
# 	7 - File is inaccessible
# 	127 - rclone (or rsync) command not found
#
# Logging
# 	-As a service (such as through systemd), logging is handled by the unit file.
# 	-Running the script directly, set `logtofile`=true. The log location is then built from the basename
# 		of the script, and goes in /var/log/{SCRIPTNAME}.log
logtofile=false

source "$(dirname "${BASH_SOURCE[0]}")/functions.sh"

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
    ["batch"]=10
    ["debug"]=false
	["min_dest_space"]="0"  # Default to 0 bytes if not provided
	["transferuser"]=""
)

[ $# -ge 4 ] || { log "Usage $0 [--src <src>] [--dest <dest>] [--trigger <trigger percent>] [--target <target percent>] [--min-dest-space <min free space in B (bytes), KB, MB, GB, or %>] [--exclude <path_to_exclude_from_tar>] [--precmd <pre-transfer command>] [--postcmd <post-transfer command>] [--batch <integer size of batch>]"; exit 2; }
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
ran_out_of_space=false
termination_requested=false
termination_signal=""
termination_exit_code=0
run_postcmd_on_termination=true
finalizing=false
current_file_src_path=""
current_dest_dir=""
finish_actions_attempted=false
scriptuser="$(whoami)"
change_user=false

if [ -n "$transferuser" ] && [ "$transferuser" != "$scriptuser" ]; then
	log "Rclone will run as user \"$transferuser\" instead of \"$scriptuser\"."
	change_user=true
fi

# Run rclone, preserve its output for logging, and translate destination-space failures into exit code 28.
run_rclone_move() {
	local output=""
	local status=0

	# if output=$(/usr/bin/sudo -u $transferuser /usr/bin/rclone move "$@" 2>&1); then
	if output=$(/usr/bin/rclone move "$@" 2>&1); then
		[ ! -z "$output" ] && log "$output"
		return 0
	fi

	status=$?
	[ ! -z "$output" ] && log "$output"

	if [[ "$output" =~ [Nn]o[[:space:]]space[[:space:]]left[[:space:]]on[[:space:]]device|[Dd]isk[[:space:]]quota[[:space:]]exceeded|[Ii]nsufficient[[:space:]]space|[Nn]ot[[:space:]]enough[[:space:]]space ]]; then
		ran_out_of_space=true
		log "Destination ran out of space while moving \"$current_file_src_path\" to \"$current_dest_dir\"."
		return 28
	fi

	return "$status"
}

# Centralize shutdown work so normal exits and trapped signals share the same finishing path.
finalize_and_exit() {
	local exit_code=${1:-0}
	local output=""
	local postcmd_status=0

	if [[ "$finalizing" = true ]]; then
		exit "$exit_code"
	fi

	finalizing=true
	trap - EXIT SIGINT SIGTERM SIGHUP
	set +e

	if [[ "$termination_requested" = true ]]; then
		case "$termination_signal" in
			SIGINT)
				log "Received SIGINT; beginning interactive shutdown."
				;;
			SIGTERM)
				log "Received SIGTERM; beginning managed shutdown."
				;;
			*)
				log "Received ${termination_signal}; beginning shutdown."
				;;
		esac
		if [[ -n "$current_file_src_path" || -n "$current_dest_dir" ]]; then
			log "Moving \"$current_file_src_path\" to \"$current_dest_dir\""
		fi
		if [[ -n "$current_dest_dir" ]]; then
			log "WARNING There may be a leftover partial transfer in \"$current_dest_dir\"."
		fi
	fi

	if [[ "$finish_actions_attempted" != true ]]; then
		finish_actions_attempted=true

		if [ "$transferflag" = true ]; then
			log "Deleting empty directories in \"$src\"."
			# Visit child directories before parents so newly emptied parents can be removed too.
			while IFS= read -r dir; do
				# Treat any remaining entry, including hidden files, as making the directory non-empty.
				if [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
					rmdir "$dir" || log "Error deleting empty directory \"$dir\"."
				fi
			# Feed the loop a depth-first list of subdirectories under src.
			done < <(find "${src}" -depth -mindepth 1 -type d)
			log 'Done.'
		fi

		if [ "$change_user" = true ]; then
			log "Switching to user \"$scriptuser\" for shutdown actions."
			su "$scriptuser"
		fi

		if [[ -n "$postcmd" && "$dryrun" = false && "$transferflag" = true ]]; then
			if [[ "$termination_requested" = true && "$run_postcmd_on_termination" != true ]]; then
				log "Skipping postcmd after ${termination_signal}."
			else
				log "Running postcmd: \"$postcmd\""

				if output=$(bash -c "$postcmd" 2>&1); then
					[ ! -z "$output" ] && log "Postcmd output: \"$output\""
				else
					postcmd_status=$?
					[ ! -z "$output" ] && log "Postcmd output: \"$output\""
					log "Postcmd failed with exit code $postcmd_status."
				fi
			fi
		fi
	fi

	log "Source at \"$src\" using $(get_current_percentage "$src")%."

	if [ "$ran_out_of_space" = true ]; then
		log "Stopped processing due to insufficient space on destination ($dest)."
		exit_code=28
	fi

	if [[ "$termination_requested" = true ]]; then
		log "Exiting due to ${termination_signal} with code ${exit_code}."
	else
		log "Finished."
	fi

	exit "$exit_code"
}

# Record which signal was received and choose the matching shutdown policy.
handle_signal() {
	termination_requested=true
	termination_signal="$1"
	case "$1" in
		SIGHUP)
			termination_exit_code=129
			run_postcmd_on_termination=true
			;;
		SIGINT)
			termination_exit_code=130
			run_postcmd_on_termination=false
			;;
		SIGTERM)
			termination_exit_code=143
			run_postcmd_on_termination=true
			;;
		*)
			termination_exit_code=128
			run_postcmd_on_termination=true
			;;
	esac
}

trap 'handle_signal SIGHUP; exit $termination_exit_code' SIGHUP
trap 'handle_signal SIGINT; exit $termination_exit_code' SIGINT
trap 'handle_signal SIGTERM; exit $termination_exit_code' SIGTERM
trap 'exit_code=$?; [[ "$termination_requested" = true ]] && exit_code=$termination_exit_code; finalize_and_exit "$exit_code"' EXIT

function get_current_percentage(){
	df -B1 --output=size,avail "$1" | tail -n 1 | awk '{ if ($1 > 0) printf "%d", (($1 - $2) * 100) / $1; else print 0 }'
}
current_usage=$(get_current_percentage "$src")

# Function to get available space in bytes for a given directory
function get_available_space() {
	df -B1 --output=avail "$1" | tail -n 1 | awk '{print $1}'
}

# Function to get total space in bytes for a given directory
function get_total_space() {
	df -B1 --output=size "$1" | tail -n 1 | awk '{print $1}'
}

# Parse min_dest_space into bytes. Bare numbers are treated as bytes.
function parse_min_dest_space_bytes() {
	local raw_value="${1:-0}"
	local total_space_bytes="$2"
	local normalized_value
	local upper_value

	normalized_value=$(echo "$raw_value" | tr -d '[:space:]')
	[[ -z "$normalized_value" ]] && normalized_value="0"
	upper_value=$(echo "$normalized_value" | tr '[:lower:]' '[:upper:]')

	if [[ "$upper_value" =~ ^([0-9]+([.][0-9]+)?)%$ ]]; then
		awk -v total="$total_space_bytes" -v pct="${BASH_REMATCH[1]}" 'BEGIN { printf "%.0f", total * pct / 100 }'
		return 0
	fi

	if [[ "$upper_value" =~ ^([0-9]+([.][0-9]+)?)(B|K|KB|M|MB|G|GB)?$ ]]; then
		local numeric_part="${BASH_REMATCH[1]}"
		local unit_part="${BASH_REMATCH[3]}"

		case "$unit_part" in
			""|B)
				awk -v value="$numeric_part" 'BEGIN { printf "%.0f", value }'
				;;
			M|MB)
				awk -v value="$numeric_part" 'BEGIN { printf "%.0f", value * 1000 * 1000 }'
				;;
			K|KB)
				awk -v value="$numeric_part" 'BEGIN { printf "%.0f", value * 1000 }'
				;;
			G|GB)
				awk -v value="$numeric_part" 'BEGIN { printf "%.0f", value * 1000 * 1000 * 1000 }'
				;;
			*)
				log "Invalid min_dest_space unit: \"$raw_value\""
				exit 2
				;;
		esac
		return 0
	fi

	log "Invalid min_dest_space value: \"$raw_value\""
	exit 2
}
current_dest_space=$(get_available_space "$dest")
current_dest_space_mb="$((current_dest_space / 1000000))"
current_dest_total_space=$(get_total_space "$dest")

# keep the user-facing value in MB, but compare in bytes
min_dest_space_input=${min_dest_space:-0}
min_dest_space=$(parse_min_dest_space_bytes "$min_dest_space_input" "$current_dest_total_space")
min_dest_space_mb="$((min_dest_space / 1000000))"

log "Initial source usage: ${current_usage}%, destination free space: ${current_dest_space_mb} MB, minimum required: ${min_dest_space_mb} MB (from \"${min_dest_space_input}\")."


# handle delta % instead of just trigger&target
if [[ ${trigger} -eq "-98" ]]; then
	# trigger was NOT provided
	if [[ ${target} -ne -99 ]]; then
		# target was provided
		delta=$(( target * ((target<0) - (target>0)) ))
		target=$(( current_usage + delta ))
		log "Source at ${src} using ${current_usage}%. Drawing down by $delta% --> $target%."
		trigger=${current_usage}
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
		log "Source at ${src} using ${current_usage}%. Goal is ${trigger}% --> ${target}%."
	fi
fi


if [ ${current_usage} -lt ${trigger} ]; then
	log "Source at ${src} using ${current_usage}%, which is below the trigger of ${trigger}%. No files will be moved."
	exit 0
fi

while [ ${current_usage} -gt ${target} ]
do
	if [[ ${current_dest_space} -lt ${min_dest_space} ]]; then
		log "Insufficient space on destination ($dest) during batch processing. Required: ${min_dest_space_mb} MB, Available: ${current_dest_space_mb} MB."
		ran_out_of_space=true
		break
	fi

	log "Disk percentage ${current_usage}% >= $target%. Destination free space ${current_dest_space_mb} MB >= ${min_dest_space_mb} MB."

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
	
	if [ ${#fileArray[@]} -eq 0 ]; then
		log "No files available to move."
		break
	else
		log "Found ${#fileArray[@]} eligible files."
	fi

	if [ "$ran_precmd" = false ]; then
		# run precmd if it has not been run and it is set
		if [ -n "$precmd" ]; then
			if [ "$dryrun" = false ]; then
				log "Running precmd \"$precmd\"."
				ran_precmd=true
				output=$(bash -c "$precmd" 2>&1)
				[ ! -z "$output" ] && log "precmd output: $output"
			else
				log "Dry-run mode: skipping precmd \"$precmd\"."
			fi
		fi
		if [ "$change_user" = true ]; then
			log "Switching to user \"$transferuser\" for transfer actions."
			ran_precmd=true
			su "$transferuser"
		fi
	fi

	# while disk usage is right and there are files left, move a batch of files
	log "Starting batch move of up to $batch files."
	count=0
	while [[ ${current_usage} -ge ${target} && ${#fileArray[@]} -gt 0 && $count -lt $batch && $current_dest_space -ge $min_dest_space ]]
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
		current_file_src_path="$file_src_path"
		current_dest_dir="$dest_dir"
		
		if [ "$dryrun" = true ]
		then
			log "Dry-running moving \"$file_src_path\" to \"$dest_dir\""
			#rsync -naSHAXWERm --delay-updates --preallocate --relative --remove-source-files "${src}/./${FILE}" "${dest}/" | log
			run_rclone_move "${file_src_path}" "${dest_dir}" --check-first --dry-run -v
			stat=$?
			[ $stat -ne 0 ] && { log "Failed to move file. Exit code $stat"; exit $stat; }
			current_file_src_path=""
			current_dest_dir=""
			break
		else
			# do real file transfer and do not exit loop
			if [[ -n "$current_file_src_path" || -n "$current_dest_dir" ]]; then
				log "Moving \"$current_file_src_path\" to \"$current_dest_dir\""
			fi
			
			#rsync -aSHAXWERm --delay-updates --preallocate --relative --remove-source-files "${src}/./${FILE}" "${dest}/" | log
			run_rclone_move "${file_src_path}" "${dest_dir}" --check-first
			stat=$?
			if [ $stat -ne 0 ]; then
				if [ "$ran_out_of_space" = true ]; then
					break
				fi
				log "Failed to move file. Exit code $stat."
				exit $stat
			fi
			transferflag=true
			current_file_src_path=""
			current_dest_dir=""
		fi

		current_dest_space=$(get_available_space "$dest")

		if [ ${#fileArray[@]} -gt 0 ]; then 
			fileArray=("${fileArray[@]:1}")
			[[ "$debug" = true ]] && log "Going to next file."
		else
			[[ "$debug" = true ]] && log "Finished batch."
			break
		fi

	done # finish batch of file moves


	current_dest_space=$(get_available_space "$dest")
	current_dest_space_mb="$((current_dest_space / 1000000))"
	current_usage=$(get_current_percentage "$src")

	if [ "$ran_out_of_space" = true ]; then
		break
	fi

	if [ "$dryrun" = true ]; then
		log "Broke batch loop after first file."
		break
	fi

done # finish all file move loops (usage % loop)


exit_code=0
[ "$ran_out_of_space" = true ] && exit_code=28
exit "$exit_code"
