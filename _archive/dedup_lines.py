# Use tqdm for progress bar
import sys
from pathlib import Path
from tqdm import tqdm

# Read in a file and de-duplicate the lines, writing the unique lines to a new file.
# `input_file.txt` -> `input_file.dedup.txt`

if len(sys.argv) != 2:
    print("Incorrect number of arguments. Usage: python script.py <input_file_path>")
    exit(1)

# Input file path (in-place deduplication)
input_data = Path(sys.argv[1]).resolve()
output_path = input_data.with_name(f"{input_data.stem}.dedup{input_data.suffix}")

total_lines = 0
# Count total lines for progress bar
with open(input_data, "r", encoding="utf-8", errors="replace") as f:
        for _ in f:                
                total_lines += 1

# Create a new output file for deduplication
with open(input_data, "r", encoding="utf-8", errors="replace") as infile:
    with open(output_path, "r+", encoding="utf-8", errors="replace") as outfile:
        for line in tqdm(infile, total=total_lines, desc="Deduplicating"):
            # Resetting the current line to check against output lines
            unique = True
            
            # Check against existing output lines
            # Note: This can lead to inefficiencies for very large files
            # In a real-world application, this would be a better approach with external storage structures.
            outfile.seek(0)  # Reset pointer to the beginning of the file
            for output_line in outfile:
                if output_line == line:
                    unique = False
                    break
            
            if unique:
                outfile.write(line)

print(f"Deduplication complete. Output written to {output_path}.")
