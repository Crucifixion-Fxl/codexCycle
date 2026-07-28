#!/bin/sh

set -eu

app_bundle="${1:?usage: create-dmg.sh <app-bundle> <output-directory>}"
output_dir="${2:?usage: create-dmg.sh <app-bundle> <output-directory>}"

if [ ! -d "${app_bundle}" ]; then
    echo "App bundle not found: ${app_bundle}" >&2
    exit 1
fi

version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "${app_bundle}/Contents/Info.plist"
)
staging_dir=$(/usr/bin/mktemp -d "/private/tmp/codexCycle-dmg.XXXXXX")
output_path="${output_dir}/codexCycle-${version}-arm64.dmg"

cleanup() {
    /bin/rm -rf "${staging_dir}"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "${output_dir}"
/usr/bin/ditto "${app_bundle}" "${staging_dir}/codexCycle.app"
/bin/ln -s /Applications "${staging_dir}/Applications"

/usr/bin/hdiutil create \
    -volname "codexCycle ${version}" \
    -srcfolder "${staging_dir}" \
    -ov \
    -format UDZO \
    "${output_path}"

/usr/bin/shasum -a 256 "${output_path}"
