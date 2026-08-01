#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <derived-data-path> <output-directory>" >&2
    exit 64
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_directory}/.." && pwd)"
derived_data_path="$1"
output_directory="$2"
project_path="${project_root}/MeetingFlowAI.xcodeproj"
entitlements_path="${project_root}/Configuration/MeetingFlowAI.entitlements"
app_path="${derived_data_path}/Build/Products/Release/MeetingFlowAI.app"
executable_path="${app_path}/Contents/MacOS/MeetingFlowAI"
zip_path="${output_directory}/MeetingFlowAI-macOS.zip"
signed_entitlements_path="${output_directory}/signed-entitlements.plist"

if ! xcode_version="$(/usr/bin/xcodebuild -version 2>&1)"; then
    echo "Unable to run xcodebuild:" >&2
    echo "${xcode_version}" >&2
    exit 1
fi
if ! /usr/bin/grep -Eq '^Xcode 26([.]|$)' <<< "${xcode_version}"; then
    echo "Xcode 26 is required. Selected developer directory:" >&2
    /usr/bin/xcode-select --print-path >&2
    echo "${xcode_version}" >&2
    exit 1
fi

/bin/mkdir -p "${derived_data_path}" "${output_directory}"

echo "Building MeetingFlowAI with ${xcode_version%%$'\n'*}"
/usr/bin/xcodebuild \
    -project "${project_path}" \
    -scheme MeetingFlowAI \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${derived_data_path}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM= \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

if [[ ! -d "${app_path}" ]]; then
    echo "Release app was not produced at ${app_path}" >&2
    exit 1
fi

if [[ ! -x "${executable_path}" ]]; then
    echo "App executable was not produced at ${executable_path}" >&2
    exit 1
fi

/usr/bin/lipo -verify_arch arm64 x86_64 "${executable_path}"

# A dash is codesign's Ad Hoc identity. Supplying the project's entitlements
# here preserves App Sandbox capabilities without a certificate or keychain.
/usr/bin/codesign \
    --force \
    --sign - \
    --options runtime \
    --timestamp=none \
    --entitlements "${entitlements_path}" \
    "${app_path}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_path}"
/usr/bin/codesign \
    --display \
    --entitlements - \
    --xml \
    "${app_path}" > "${signed_entitlements_path}"
/usr/bin/plutil -lint "${signed_entitlements_path}"

required_entitlements=(
    com.apple.security.app-sandbox
    com.apple.security.device.audio-input
    com.apple.security.files.user-selected.read-write
    com.apple.security.network.client
)

for entitlement in "${required_entitlements[@]}"; do
    # plutil treats dots as key-path separators, so literal dots are escaped.
    escaped_entitlement="${entitlement//./\\.}"
    if ! value="$(
        /usr/bin/plutil \
            -extract "${escaped_entitlement}" \
            raw \
            -o - \
            "${signed_entitlements_path}"
    )"; then
        echo "Missing signed entitlement: ${entitlement}" >&2
        exit 1
    fi
    if [[ "${value}" != "true" ]]; then
        echo "Missing signed entitlement: ${entitlement}" >&2
        exit 1
    fi
done

signature_details="$(
    /usr/bin/codesign --display --verbose=4 "${app_path}" 2>&1
)"
if ! /usr/bin/grep -q 'Signature=adhoc' <<< "${signature_details}"; then
    echo "The app does not have an Ad Hoc signature." >&2
    exit 1
fi
if ! /usr/bin/grep -Eq 'flags=.*runtime' <<< "${signature_details}"; then
    echo "The app signature does not enable Hardened Runtime." >&2
    exit 1
fi

/bin/rm -f "${zip_path}"
/usr/bin/ditto \
    -c \
    -k \
    --sequesterRsrc \
    --keepParent \
    "${app_path}" \
    "${zip_path}"
/usr/bin/unzip -tq "${zip_path}"

echo "Created ${zip_path}"
