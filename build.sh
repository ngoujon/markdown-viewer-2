#!/bin/bash
# Compile et installe Markdown Viewer.app dans /Applications, puis le
# définit comme lecteur par défaut des fichiers .md / .markdown.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Markdown Viewer.app"
DEST="/Applications/$APP_NAME"
BUILD="$ROOT/build"

echo "==> Compilation"
mkdir -p "$BUILD"
swiftc -O \
  "$ROOT/Sources/MarkdownViewer/MarkdownRenderer.swift" \
  "$ROOT/Sources/MarkdownViewer/main.swift" \
  -o "$BUILD/MarkdownViewer"

echo "==> Packaging du bundle .app"
rm -rf "$BUILD/$APP_NAME"
mkdir -p "$BUILD/$APP_NAME/Contents/MacOS"
mkdir -p "$BUILD/$APP_NAME/Contents/Resources"
cp "$BUILD/MarkdownViewer" "$BUILD/$APP_NAME/Contents/MacOS/MarkdownViewer"
cp "$ROOT/Resources/Info.plist" "$BUILD/$APP_NAME/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUILD/$APP_NAME/Contents/Resources/AppIcon.icns"
fi

echo "==> Installation dans /Applications"
rm -rf "$DEST"
cp -R "$BUILD/$APP_NAME" "/Applications/"

echo "==> Enregistrement auprès de Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

if command -v duti >/dev/null 2>&1; then
  echo "==> Définition comme application par défaut pour .md / .markdown"
  duti -s local.ngoujon.markdownviewer net.daringfireball.markdown viewer || true
  duti -s local.ngoujon.markdownviewer .md all || true
  duti -s local.ngoujon.markdownviewer .markdown all || true
else
  echo "duti introuvable : impossible de définir automatiquement l'app par défaut."
fi

echo "==> Terminé : $DEST"
