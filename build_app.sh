#!/bin/bash
set -e

# Build the release binary (optimized, no DEBUG-only code paths)
swift build -c release

# Create the app bundle directory structure
mkdir -p ClipboardVault.app/Contents/MacOS
mkdir -p ClipboardVault.app/Contents/Resources

# Copy the binary
cp .build/release/ClipboardVault ClipboardVault.app/Contents/MacOS/

# Copy the icon
if [ -f app_icon.icns ]; then
    cp app_icon.icns ClipboardVault.app/Contents/Resources/
fi

# Create Info.plist
cat > ClipboardVault.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClipboardVault</string>
    <key>CFBundleIdentifier</key>
    <string>com.thuongtamduy.ClipboardVault</string>
    <key>CFBundleName</key>
    <string>ClipboardVault</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>app_icon</string>
</dict>
</plist>
EOF

echo "Build successful: ClipboardVault.app created with icon!"
