#! /usr/bin/env python3
import requests
import os
from tqdm import tqdm  # Import tqdm

# Sonarr API details
RESULTS_FILE = 'orphaned_files.txt'
MEDIA_DIRECTORY = '/media/series'
API_KEY = '<api-key>'
HOST = 'http://localhost:8989'
SUFFIX = '/api/v3/series'
SONARR_URL = ''.join([HOST, SUFFIX])

# Define the file extensions you want to check
VALID_EXTENSIONS = ('.mkv', '.mp4', '.avi')  # Adjust as needed

def get_sonarr_series():
    response = requests.get(SONARR_URL, headers={'X-Api-Key': API_KEY})
    if response.status_code != 200:
        print(f"Failed to connect to Sonarr: {response.status_code}")
        return {}
    print(f'Connected to Sonarr at {HOST}')
    return (series['path'] for series in response.json())

def find_orphaned_files(series):
        orphaned_files = []
        filtered_files = []
        filtered_paths = []
        all_series_files = set()  # To store all known media filenames

        # Collect all known media files from the series tracked by Sonarr
        for s_path in series:
                for root, dirs, files in os.walk(s_path):
                        for file in files:
                                if file.endswith(VALID_EXTENSIONS):
                                        all_series_files.add(os.path.join(root,file).lower())  # Store the lowercase filenames

        print(f"Known database files collected: {len(all_series_files)}")

        # Walk through the media directory to find orphaned files
        for root, dirs, files in os.walk(MEDIA_DIRECTORY):
                filtered_paths.extend([os.path.join(root,file).lower() for file in files if file.endswith(VALID_EXTENSIONS)])
        
        print(f"Found {len(filtered_paths)} eligible files in {MEDIA_DIRECTORY}.")
        if not filtered_paths:
            return []  # Skip if no eligible files
            
        for file in tqdm(filtered_paths, desc="Scanning files"):
            # Check if the filename (lowercased) is in the known series files
            if file.lower() not in all_series_files:
                orphaned_files.append(file)
        
        filtered_paths = set(filtered_paths)
        exclusive_files = ( all_series_files - filtered_paths ) | ( filtered_paths - all_series_files )

        return orphaned_files, exclusive_files


sonarr_series = get_sonarr_series()
if not sonarr_series:
        exit(0)
orphaned_files, exclusive_files = find_orphaned_files(sonarr_series)

# Output handling
if orphaned_files:
    # Write to output file if more than 10 results
    if len(orphaned_files) > 10:
        with open(RESULTS_FILE, 'w') as output_file:
            for file in orphaned_files:
                output_file.write(f"{file}\n")
        print(f"Orphaned files ({len(orphaned_files)}) found. Results written to '{RESULTS_FILE}'.")
    else:
        print("Orphaned files found:")
        for file in orphaned_files:
            print(file)
else:
    print("No orphaned files found.")
    
if exclusive_files:
        print(f"Exclusive files {len(exclusive_files)} were either not found in the database or not found on disk.")
        with open(''.join(RESULTS_FILE.split('.')[:-1])+'_exclusive.'+''.join(RESULTS_FILE.split('.')[-1]), 'w') as output_file:
                for file in exclusive_files:
                        output_file.write(f"{file}\n")

