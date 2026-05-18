#!/bin/bash

# Create a temporary iconset directory
mkdir -p app_icon.iconset

# Generate icons of different sizes using sips
sips -s format png -z 16 16     app_icon.png --out app_icon.iconset/icon_16x16.png
sips -s format png -z 32 32     app_icon.png --out app_icon.iconset/icon_16x16@2x.png
sips -s format png -z 32 32     app_icon.png --out app_icon.iconset/icon_32x32.png
sips -s format png -z 64 64     app_icon.png --out app_icon.iconset/icon_32x32@2x.png
sips -s format png -z 128 128   app_icon.png --out app_icon.iconset/icon_128x128.png
sips -s format png -z 256 256   app_icon.png --out app_icon.iconset/icon_128x128@2x.png
sips -s format png -z 256 256   app_icon.png --out app_icon.iconset/icon_256x256.png
sips -s format png -z 512 512   app_icon.png --out app_icon.iconset/icon_256x256@2x.png
sips -s format png -z 512 512   app_icon.png --out app_icon.iconset/icon_512x512.png
sips -s format png -z 1024 1024 app_icon.png --out app_icon.iconset/icon_512x512@2x.png

# Convert iconset to icns
iconutil -c icns app_icon.iconset

# Clean up
rm -rf app_icon.iconset

if [ -f app_icon.icns ]; then
    echo "app_icon.icns created successfully!"
else
    echo "Failed to create app_icon.icns"
fi
