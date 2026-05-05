# Use tqdm for progress bar
import sys
from pathlib import Path
from tqdm import tqdm
import re

# Read in a file and de-duplicate the lines, writing the unique lines to a new file. The script is designed to handle large files, 
# so it processes the input line by line, preserving memory in exchange for speed.
# `input_file.txt` -> `input_file.dedup.txt`
# 
# If `input_file.dedup.txt` already exists, it will be overwritten.
# 
# The script also:
# - removes empty or whitespace-only lines
# - replaces lines that contain a single IP address range with just the IP address (e.g., `123.456.123.456-123.456.123.456` ==> `123.456.123.456`)
# - removes lines that contain non-matching IP address ranges (e.g., `123.456.123.456-111.222.333.444` ==> ``)
# - preserves lines that do not match the above conditions

if len(sys.argv) != 2:
    print("Incorrect number of arguments. Usage: python dedup_lines.py <input_file_path>")
    exit(1)

# Input file path (in-place deduplication)
input_data = Path(sys.argv[1]).resolve()
output_path = input_data.with_name(f"{input_data.stem}.dedup{input_data.suffix}")

total_lines = 0
# Count total lines for progress bar
with open(input_data, "r", encoding="utf-8", errors="replace") as f:
        for _ in f:                
                total_lines += 1

octet = r'(?:25[0-5]|2[0-4]\d|1?\d{1,2})'
ip = fr'({octet}(?:\.{octet}){{3}})'
ip_re = re.compile(ip)
ip_pair_re = re.compile(fr'{ip}\s*-\s*{ip}')

def contains_ip(line):
    return ip_re.search(line) is not None

def squash_to_single_ip(line):
    match = ip_pair_re.search(line)

    if match:
        # Line has ip range
        if match.group(1) == match.group(2):
            # If the two IPs in the range are the same
            return match.group(1)
        else:
            # If the two IPs in the range are different
            return ''
    else:
        # Does not contain an IP range, return the line as is
        return line


print(f"Starting de-duplication of {input_data} with {total_lines} total lines to {output_path}...")
wrote_lines=0

# Create a new output file for deduplication
with open(input_data, "r", encoding="utf-8", errors="replace") as infile:
    with open(output_path, "w+", encoding="utf-8", errors="replace") as outfile:
        for line in tqdm(infile, total=total_lines, desc="De-duplicating"):
            line = line.strip()
            if line == '':
                continue
            if contains_ip(line):
                line = squash_to_single_ip(line)
                if line == '':
                    continue

            ### Check against existing output lines
            # Reset the current line to check against output lines
            unique = True
            # Reset the pointer to the beginning of the output file
            outfile.seek(0)
            # Iterate through existing lines in the output file to check for duplicates
            for output_line in outfile:
                if output_line.rstrip('\n') == line:
                    # Duplicate found
                    unique = False
                    break
            
            # Write unique line to output file
            if unique is True:
                outfile.write(line+'\n')
                outfile.flush()
                wrote_lines += 1


print(f"De-duplication complete. Output of {wrote_lines} lines written to {output_path}.")
