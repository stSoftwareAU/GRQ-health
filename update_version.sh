#!/bin/bash
set -euo pipefail

# Script to update version in HTML files from run.sh
# This ensures version consistency across the project

# Get the version from run.sh
if [ ! -f "run.sh" ]; then
    echo "Error: run.sh not found"
    exit 1
fi

VERSION=$(grep '^VERSION=' run.sh | cut -d'"' -f2 || echo "")

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
    
    # Version display is now dynamic via JavaScript, no need to update static HTML
    
    # Clean up backup files
    rm -f docs/index.html.bak
    
    echo "Updated docs/index.html with version $VERSION"
else
    echo "Warning: docs/index.html not found"
fi

# Update simple.html
if [ -f "docs/simple.html" ]; then
    # Update CSS link
    sed -i.bak "s|styles\.css?v=[0-9.]*|styles.css?v=$VERSION|g" docs/simple.html
    
    # Update JS link
    sed -i.bak "s|dashboard\.js?v=[0-9.]*|dashboard.js?v=$VERSION|g" docs/simple.html
    
    # Version display is now dynamic via JavaScript, no need to update static HTML
    
    # Clean up backup files
    rm -f docs/simple.html.bak
    
    echo "Updated docs/simple.html with version $VERSION"
else
    echo "Warning: docs/simple.html not found"
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

# Update service worker (sw.js)
if [ -f "docs/sw.js" ]; then
    # Update the service worker version comment
    sed -i.bak "s/\/\/ Version: [0-9.]*/\/\/ Version: $VERSION/g" docs/sw.js
    
    # Update cache names
    sed -i.bak "s/grq-health-v[0-9.]*/grq-health-v$VERSION/g" docs/sw.js
    sed -i.bak "s/grq-health-static-v[0-9.]*/grq-health-static-v$VERSION/g" docs/sw.js
    
    # Update dashboard.js reference in cache list
    sed -i.bak "s|dashboard\.js?v=[0-9.]*|dashboard.js?v=$VERSION|g" docs/sw.js
    
    # Clean up backup files
    rm -f docs/sw.js.bak
    
    echo "Updated docs/sw.js with version $VERSION"
else
    echo "Warning: docs/sw.js not found"
fi

echo "Version update complete!"
