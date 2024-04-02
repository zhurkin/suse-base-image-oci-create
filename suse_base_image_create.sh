#!/usr/bin/env
#
# Script Name: suse_base_image_create.sh
# Description: This script installs necessary packages and configures repositories to create a base image of SUSE Linux for OCI (Open Container Initiative) compliant containers
# Author: Vladimir Zhurkin
# Date: April 3, 2024
# License: MIT
#
# Copyright (c) 2024 Vladimir Zhurkin
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -e

archive_version="v1.0"
archive_include_build_time="n"
archive_filename="suse-base-image"
archive_path="/root"
install_dir="/mnt/opensuse"
remove_install_dir_flag="n"
zypp_cache_dir="$install_dir/var/cache/zypp"

# List of packages to install
packages_to_install="aaa_base zypper ca-certificates ca-certificates-mozilla timezone"

# Main repository URL variable
s_repo="download.opensuse.org"

# Array with repository information in the format NAME_REPOSITORY|LOCATION|ALIAS
repositories=(
    "Main Repository|distribution/leap/15.5/repo/oss/|repo-oss|99"
    "Update Repository|update/leap/15.5/oss|repo-update|99"
    "Repository Non-OSS|distribution/leap/15.5/repo/non-oss/|repo-non-oss|99"
    "Update Repository Non-OSS|update/leap/15.5/non-oss/|repo-update-non-oss|99"
    "Update repository of openSUSE Backports|update/leap/15.5/backports/|repo-backports-update|99"
    "Update repository with updates from SUSE Linux Enterprise 15|update/leap/15.5/non-oss/|repo-sle-update|99"
)

# Function to check the existence of the zypper command
check_zypper_existence() {
    if ! command -v zypper &> /dev/null; then
        echo "Error: Command 'zypper' not found. Make sure you are running on a supported operating system."
        exit 1
    fi
}

# Function to mount filesystems
mount_filesystems() {
    mount -t proc none "$install_dir/proc"
    mount --bind /dev "$install_dir/dev"
}

# Function to unmount filesystems
umount_filesystems() {
    umount "$install_dir/proc" "$install_dir/dev"
}

# Function to remove .repo files from directories, if they exist
remove_repo_files() {
    local repos_dir="$install_dir/etc/zypp/repos.d/"
    local cache_dir="$install_dir/var/cache/zypp/"

    # Check if repos.d directory exists and remove .repo files
    if [ -d "$repos_dir" ]; then
        rm -f "$repos_dir"*.repo
    fi

    # Check if var/cache/zypp directory exists and clear its contents
    if [ -d "$cache_dir" ]; then
        rm -rf "$cache_dir"*
    fi
}

# Function add repositories
add_repositories() {
    local repo_info
    local error_occurred=false  # Flag to track errors
    IFS='|'
    for repo_info in "${repositories[@]}"; do
        # Reading repository information
        read -r name location alias priority <<< "$repo_info"
        uri="${s_repo}${location}"
        # Adding repository
        if ! zypper -v -D "$zypp_cache_dir" -C "$zypp_cache_dir" --raw-cache-dir "$zypp_cache_dir" -R "$install_dir" ar -k -n "$name" -p "$priority" "$uri" "$alias"; then
            # If the command fails, set the error flag and continue the loop
            echo "Error adding repository: $name."
            error_occurred=true
        fi
    done

    # Checking the error flag
    if [ "$error_occurred" = true ]; then
        # If there are errors, display a message and unmount filesystems
        echo "An error occurred while adding repositories. Unmounting filesystems and exiting."
        umount_filesystems
        exit 1
    fi
}

# Function to update repositories
update_repositories() {
    if ! zypper -v -D "$zypp_cache_dir" --raw-cache-dir "$zypp_cache_dir" -R "$install_dir" --gpg-auto-import-keys ref; then
        echo "Error updating repositories. Unmounting filesystems and exiting."
        umount_filesystems
        exit 1
    fi
}

# Function to install packages
install_packages() {
    # Convert string to array
    IFS=' ' read -r -a packages_array <<< "$packages_to_install"

    # Install packages from the array
    if ! zypper -v -D "$zypp_cache_dir" --raw-cache-dir "$zypp_cache_dir" -R "$install_dir" in -y "${packages_array[@]}"; then
        echo "Error installing packages. Unmounting filesystems and exiting."
        umount_filesystems
        exit 1
    fi
}

cleanup() {
    # Clean cache
    if ! zypper -v -D "$zypp_cache_dir" --raw-cache-dir "$zypp_cache_dir" -R "$install_dir" clean -a; then
        echo "Error cleaning cache. Unmounting filesystems and exiting."
        umount_filesystems
        exit 1
    fi
}

# Function to archive the installed system
archive_system() {
    local tar_args="-cf"

    # Check if archive version is specified
    if [ -n "$archive_version" ]; then
        archive_filename="$archive_filename-$archive_version"
    fi

    # Check if build time should be included in the archive filename
    if [ "${archive_include_build_time,,}" = "y" ]; then
        build_time=$(date +"%Y-%m-%d")
        archive_filename="$archive_filename-$build_time"
    fi

    local archive_full_path="$archive_path/$archive_filename.tar"

    # Attempt to archive
    if ! tar $tar_args "$archive_full_path" --numeric-owner -C "$install_dir" .; then
        # If an error occurs, display a message and exit the script
        echo "Error archiving the installed system. Process terminated."
        exit 1
    fi
}

# Function to remove the install_dir directory
remove_install_dir() {
    # Check if dev and proc are mounted
    if grep -qs "$install_dir/dev" /proc/mounts && grep -qs "$install_dir/proc" /proc/mounts; then
        echo "Directories /mnt/opensuse/dev and /mnt/opensuse/proc are mounted. Unable to delete $install_dir."
        return
    fi

    if [ "${remove_install_dir_flag,,}" = "y" ]; then
        echo "Removing directory $install_dir"
        rm -rf "$install_dir"
    else
        echo "Flag to remove directory is not set. $install_dir will not be deleted."
    fi
}

# Create necessary directories
mkdir -p "$install_dir/dev" "$zypp_cache_dir" "$install_dir/proc" "$install_dir/etc/zypp/repos.d"

# check zypper
check_zypper_existence

# Mount filesystems
mount_filesystems

# Call the function to remove .repo files before adding repositories
remove_repo_files

# Add repositories
add_repositories

# Update repositories
update_repositories

# Use the function to install packages
install_packages

# Clean up cache
cleanup

# Move repository files
mv "$zypp_cache_dir"/*.repo "$install_dir/etc/zypp/repos.d/" || exit 1

# Write installation history
> "$install_dir/var/log/zypp/history" || exit 1

# Unmount filesystems
umount_filesystems

# Function to archive the installed system
archive_system

# Remove install_dir directory if necessary
remove_install_dir
