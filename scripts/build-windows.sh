#!/bin/zsh
set -eu
cd "${0:A:h:h}"
DOTNET="${CLIPDAY_DOTNET:-dotnet}"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "$DOTNET" publish Windows/ClipDay.Cloud -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o build/windows-x64 --nologo
