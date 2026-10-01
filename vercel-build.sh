#!/bin/bash
set -e

echo ">>> [Vercel Build] Installing Flutter SDK..."
if [ ! -d "$HOME/flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
fi

export PATH="$PATH:$HOME/flutter/bin"

echo ">>> [Vercel Build] Flutter CLI Ready:"
flutter --version

echo ">>> [Vercel Build] Compiling Flutter Web Release..."
flutter config --no-analytics
flutter pub get
flutter build web --release

echo ">>> [Vercel Build] Successfully compiled to build/web"
