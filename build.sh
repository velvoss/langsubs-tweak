#!/bin/sh
# macOS + Xcode command line tools
set -e
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=14.0 -fobjc-arc -dynamiclib \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
  -framework AVFoundation -framework NaturalLanguage -install_name @rpath/LangSubsTap.dylib \
  -o LangSubsTap.dylib Tweak.m
echo "built LangSubsTap.dylib"
