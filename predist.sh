#!/bin/sh

# Generate CHANGES.darcs
[ -d "$DARCS_REPO" ] && darcs changes --repodir "$DARCS_REPO" > CHANGES.darcs

# Build the user manual for release
make -C manual all clean-aux

# Add OASIS stuff
oasis setup

# Make the configure script executable
chmod +x configure

# Cleanup
rm -f predist.sh boring
