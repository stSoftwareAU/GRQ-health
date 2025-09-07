#!/bin/bash

# Script to update version in HTML files from run.sh
# This ensures version consistency across the project

set -e

# Get the version from run.sh
VERSION=$(grep '^VERSION=' run.sh | cut -d'"' -f2)

if [ -z "$VERSION" ]; then
    echo "Error: Could not find VERSION in run.sh"
    exit 1
fi

echo "Updating version to $VERSION in HTML files..."

# Update index.html
if [ -f "docs/index.html" ]; then
    # Update CSS link
    sed -i.bak "s|styles\.css?v=[0-9.]*|styles.css?v=$VERSION|g" docs/index.html
    
    # Update JS link
    sed -i.bak "s|dashboard\.js?v=[0-9.]*|dashboard.js?v=$VERSION|g" docs/index.html
    
    # Update service worker link
    sed -i.bak "s|sw\.js?v=[0-9.]*|sw.js?v=$VERSION|g" docs/index.html
    
    # Update version display
    sed -i.bak "s|<span id=\"version\">[0-9.]*</span>|<span id=\"version\">$VERSION</span>|g" docs/index.html
    
    # Clean up backup files
    rm -f docs/index.html.bak
    
    echo "Updated docs/index.html with version $VERSION"
else
    echo "Warning: docs/index.html not found"
fi

# Update dashboard.js
if [ -f "docs/dashboard.js" ]; then
    # Update the VERSION constant
    sed -i.bak "s/const VERSION = \"[0-9.]*\";/const VERSION = \"$VERSION\";/g" docs/dashboard.js
    
    # Clean up backup files
    rm -f docs/dashboard.js.bak
    
    echo "Updated docs/dashboard.js with version $VERSION"
else
    echo "Warning: docs/dashboard.js not found"
fi

echo "Version update complete!"
