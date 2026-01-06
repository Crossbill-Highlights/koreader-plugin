#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
else
    echo "Error: .env file not found in $SCRIPT_DIR"
    echo "Please copy .env.example to .env and configure it"
    exit 1
fi

# Check if the target path is set
if [ -z "$KOREADER_PLUGINS_PATH" ]; then
    echo "Error: KOREADER_PLUGINS_PATH is not set in .env"
    exit 1
fi

echo "Copying production plugin..."
# Remove old plugins first to ensure clean copy (cp -R merges, doesn't replace)
rm -rf "$KOREADER_PLUGINS_PATH/crossbill.koplugin"
rm -rf "$KOREADER_PLUGINS_PATH/crossbill-test.koplugin"
# Copy the production plugin
cp -R "$SCRIPT_DIR/crossbill.koplugin" "$KOREADER_PLUGINS_PATH/"

echo "Creating test plugin..."
# Create a temporary directory for the test plugin
TMP_TEST_DIR=$(mktemp -d)
cp -R "$SCRIPT_DIR/crossbill.koplugin" "$TMP_TEST_DIR/crossbill-test.koplugin"

# Modify _meta.lua for test version
sed -i 's/name = "Crossbill"/name = "Crossbill Test"/' "$TMP_TEST_DIR/crossbill-test.koplugin/_meta.lua"
sed -i 's/fullname = _("Crossbill Sync")/fullname = _("Crossbill Test Sync")/' "$TMP_TEST_DIR/crossbill-test.koplugin/_meta.lua"
sed -i 's/description = _(\[\[Syncs your highlights to Crossbill server for editing and management.\]\])/description = _([[TEST VERSION - Syncs your highlights to Crossbill server for editing and management.]])/' "$TMP_TEST_DIR/crossbill-test.koplugin/_meta.lua"

# Rename modules directory to avoid Lua require cache conflicts
# (Lua caches "modules/ui" globally, so both plugins would share the same module)
mv "$TMP_TEST_DIR/crossbill-test.koplugin/modules" "$TMP_TEST_DIR/crossbill-test.koplugin/test_modules"

# Modify main.lua for test version
# Change the class name
sed -i 's/name = "Crossbill"/name = "Crossbill Test"/' "$TMP_TEST_DIR/crossbill-test.koplugin/main.lua"
# Change the menu key to avoid conflicts with production
sed -i 's/menu_items\.crossbill_sync/menu_items.crossbill_test_sync/g' "$TMP_TEST_DIR/crossbill-test.koplugin/main.lua"
# Update require paths to use renamed modules directory (in main.lua and all module files)
find "$TMP_TEST_DIR/crossbill-test.koplugin" -name "*.lua" -exec sed -i 's|require("modules/|require("test_modules/|g' {} \;

# Modify test_modules/settings.lua for test version
# Change settings key to separate from production version
sed -i 's/crossbill_sync/crossbill_test_sync/g' "$TMP_TEST_DIR/crossbill-test.koplugin/test_modules/settings.lua"

# Modify test_modules/ui.lua for test version
# Change menu text
sed -i 's/_("Crossbill Sync")/_("Crossbill Test Sync")/g' "$TMP_TEST_DIR/crossbill-test.koplugin/test_modules/ui.lua"

# Modify test_modules/sessiontracker.lua for test version
# Change database filename to avoid conflicts with production
sed -i 's/crossbill_sessions\.sqlite3/test_crossbill_sessions.sqlite3/g' "$TMP_TEST_DIR/crossbill-test.koplugin/test_modules/sessiontracker.lua"

# Copy test plugin to destination
cp -R "$TMP_TEST_DIR/crossbill-test.koplugin" "$KOREADER_PLUGINS_PATH/"

# Clean up temporary directory
rm -rf "$TMP_TEST_DIR"

echo "Done! Installed both production and test versions."
