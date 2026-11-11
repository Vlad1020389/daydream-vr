#!/usr/bin/env bash
# Сборка AAR-плагина DaydreamBle и копирование в addons/daydream_ble/bin.
# Нужны: JDK 17, Android SDK (ANDROID_HOME) и установленный gradle 8.x
# (либо откройте папку android_plugin в Android Studio и выполните assembleRelease).
set -euo pipefail

cd "$(dirname "$0")"
gradle --no-daemon assembleRelease

mkdir -p ../addons/daydream_ble/bin
cp build/outputs/aar/*-release.aar ../addons/daydream_ble/bin/daydream_ble.aar
echo "Готово: addons/daydream_ble/bin/daydream_ble.aar"
