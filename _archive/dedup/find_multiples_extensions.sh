#!/bin/bash
#~ ext=$1

#~ find . -type d | while read -r folder; do
	#~ count=$(find "$folder" -type f -name "$ext" | wc -l)
	#~ if [ "$count" -gt 1 ]; then
		#~ echo "$folder"
	#~ fi
#~ done

# Find subfolders with more than one file matching any of the specified extensions

# Accept multiple extensions as input
extensions=("$@")

# Check if any extensions are provided
if [ ${#extensions[@]} -eq 0 ]; then
    echo "Usage: $0 ext1 ext2 ... extN"
    exit 1
fi

# Loop through each subfolder and count files matching the specified extensions
find . -type d | while read -r folder; do
    count=0
    for ext in "${extensions[@]}"; do
        count=$(($count + $(find "$folder" -type f -name "$ext" | wc -l)))
    done
    if [ "$count" -gt 1 ]; then
        echo "$folder"
    fi
done
