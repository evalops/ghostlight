#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_DIR/dist}"
MINIMUM_MACOS="14.0"

for command_name in swift lipo codesign plutil ditto shasum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done

[[ ! -L "$OUTPUT_DIR" ]] || {
  printf 'refusing symlink output directory: %s\n' "$OUTPUT_DIR" >&2
  exit 1
}

head_revision="$(git -C "$REPO_DIR" rev-parse HEAD)"
source_revision="${GHOSTLIGHT_SOURCE_REVISION:-$head_revision}"
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'invalid source revision: %s\n' "$source_revision" >&2
  exit 1
}
[[ "$source_revision" == "$head_revision" ]] || {
  printf 'source revision %s does not match HEAD %s\n' "$source_revision" "$head_revision" >&2
  exit 1
}
source_tree=clean
if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=all)" ]]; then
  source_tree=dirty
  [[ "${GHOSTLIGHT_ALLOW_DIRTY:-0}" == 1 ]] || {
    printf 'refusing to package a dirty tracked source tree\n' >&2
    exit 1
  }
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"

version="$(plutil -extract CFBundleShortVersionString raw -o - "$SCRIPT_DIR/Resources/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'invalid app version: %s\n' "$version" >&2
  exit 1
}

archive_name="Ghostlight-${version}-macos-universal.zip"
archive_path="$OUTPUT_DIR/$archive_name"
build_info_path="$OUTPUT_DIR/BUILD-INFO.txt"
checksum_path="$OUTPUT_DIR/SHA256SUMS"
[[ ! -e "$archive_path" && ! -e "$build_info_path" && ! -e "$checksum_path" ]] || {
  printf 'release output already exists in %s\n' "$OUTPUT_DIR" >&2
  exit 1
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/ghostlight-release.XXXXXX")"
cleanup() {
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/ghostlight-release.*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      printf 'refusing unexpected temporary cleanup path: %s\n' "$temporary_root" >&2
      ;;
  esac
}
trap cleanup EXIT

build_binary() {
  local architecture=$1
  local triple="${architecture}-apple-macosx${MINIMUM_MACOS}"
  local scratch="$temporary_root/build-$architecture"
  local binary_dir

  swift build \
    --package-path "$SCRIPT_DIR" \
    --scratch-path "$scratch" \
    --configuration release \
    --triple "$triple" >&2
  binary_dir="$(
    swift build \
      --package-path "$SCRIPT_DIR" \
      --scratch-path "$scratch" \
      --configuration release \
      --triple "$triple" \
      --show-bin-path
  )"
  [[ -x "$binary_dir/GhostlightApp" ]] || {
    printf 'release binary is missing for %s\n' "$architecture" >&2
    exit 1
  }
  printf '%s\n' "$binary_dir/GhostlightApp"
}

arm64_binary="$(build_binary arm64)"
x86_64_binary="$(build_binary x86_64)"

app_dir="$temporary_root/Ghostlight.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
mkdir -p "$macos_dir"
cp "$SCRIPT_DIR/Resources/Info.plist" "$contents_dir/Info.plist"
lipo -create \
  -output "$macos_dir/GhostlightApp" \
  "$arm64_binary" \
  "$x86_64_binary"
chmod 755 "$macos_dir/GhostlightApp"

architectures="$(lipo -archs "$macos_dir/GhostlightApp")"
[[ "$architectures" == *arm64* ]]
[[ "$architectures" == *x86_64* ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$contents_dir/Info.plist")" == "org.evalops.Ghostlight" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$contents_dir/Info.plist")" == "$version" ]]

codesign --force --timestamp=none --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"
archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
swift_version="$(swift --version | paste -sd ' ' -)"
cat >"$build_info_path" <<EOF
Ghostlight macOS release build
version=$version
bundle_build=$(plutil -extract CFBundleVersion raw -o - "$contents_dir/Info.plist")
source_revision=$source_revision
source_tree=$source_tree
minimum_macos=$MINIMUM_MACOS
architectures=$architectures
codesign_identity=adhoc
notarized=no
swift=$swift_version
archive=$archive_name
archive_sha256=$archive_sha256
EOF
(
  cd -- "$OUTPUT_DIR"
  shasum -a 256 "$archive_name" "$(basename -- "$build_info_path")" >"$(basename -- "$checksum_path")"
)

printf 'archive=%s\nbuild_info=%s\nchecksum=%s\nversion=%s\narchitectures=%s\n' \
  "$archive_path" \
  "$build_info_path" \
  "$checksum_path" \
  "$version" \
  "$architectures"
