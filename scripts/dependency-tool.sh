#!/bin/bash
set -euo pipefail

BACKEND_SEARCH_PATH_SET="${PATH+x}"
BACKEND_SEARCH_PATH="${PATH-}"
PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST_PATH="${TALKTEXT_DEPENDENCY_MANIFEST:-$REPOSITORY_ROOT/dependencies.env}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ -r "$MANIFEST_PATH" ]] || fail "dependency manifest is not readable: $MANIFEST_PATH"
# shellcheck source=/dev/null
source "$MANIFEST_PATH"

required_manifest_keys=(
    TALKTEXT_DEPENDENCY_MANIFEST_VERSION
    MODEL_REPOSITORY MODEL_REVISION MODEL_FILE_NAME MODEL_URL
    MODEL_SIZE_BYTES MODEL_SHA256 MODEL_MAGIC_HEX
    BACKEND_FORMULA BACKEND_EXECUTABLE BACKEND_REPOSITORY_URL BACKEND_SUPPORTED_VERSIONS
    BACKEND_UPSTREAM_REVISIONS BACKEND_REQUIRED_FLAGS
)

for key in "${required_manifest_keys[@]}"; do
    [[ -n "${!key:-}" ]] || fail "dependency manifest is missing $key"
done

[[ "$MODEL_SIZE_BYTES" =~ ^[0-9]+$ ]] || fail "MODEL_SIZE_BYTES must be an integer"
[[ "$MODEL_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "MODEL_SHA256 must be a lowercase SHA-256 digest"
[[ "$MODEL_MAGIC_HEX" =~ ^[0-9a-f]+$ ]] || fail "MODEL_MAGIC_HEX must contain lowercase hexadecimal bytes"
[[ "$MODEL_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "MODEL_REVISION must be a full immutable Git revision"
EXPECTED_MODEL_URL="https://huggingface.co/$MODEL_REPOSITORY/resolve/$MODEL_REVISION/$MODEL_FILE_NAME"
[[ "$MODEL_URL" == "$EXPECTED_MODEL_URL" ]] || fail "MODEL_URL must resolve MODEL_FILE_NAME at the pinned MODEL_REVISION"
[[ "$BACKEND_REPOSITORY_URL" == https://* ]] || fail "BACKEND_REPOSITORY_URL must use HTTPS"

for supported_version in $BACKEND_SUPPORTED_VERSIONS; do
    pinned_revision=''
    for version_revision in $BACKEND_UPSTREAM_REVISIONS; do
        if [[ "${version_revision%%=*}" == "$supported_version" ]]; then
            pinned_revision="${version_revision#*=}"
            break
        fi
    done
    [[ "$pinned_revision" =~ ^[0-9a-f]{40}$ ]] || fail "backend $supported_version must have one full pinned upstream revision"
done

file_size() {
    local path="$1"
    if stat -f '%z' "$path" >/dev/null 2>&1; then
        stat -f '%z' "$path"
    else
        stat -c '%s' "$path"
    fi
}

file_sha256() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        fail "neither shasum nor sha256sum is available"
    fi
}

file_magic() {
    od -An -tx1 -N "$(( ${#MODEL_MAGIC_HEX} / 2 ))" "$1" | tr -d '[:space:]'
}

verify_model() {
    local path="$1"
    local actual

    [[ -f "$path" ]] || { echo "model is missing: $path" >&2; return 1; }
    [[ -r "$path" ]] || { echo "model is not readable: $path" >&2; return 1; }

    actual="$(file_size "$path")"
    [[ "$actual" == "$MODEL_SIZE_BYTES" ]] || {
        echo "model size mismatch at $path (expected $MODEL_SIZE_BYTES bytes, found $actual)" >&2
        return 1
    }

    actual="$(file_magic "$path")"
    [[ "$actual" == "$MODEL_MAGIC_HEX" ]] || {
        echo "model format mismatch at $path (expected magic $MODEL_MAGIC_HEX, found ${actual:-empty})" >&2
        return 1
    }

    actual="$(file_sha256 "$path")"
    [[ "$actual" == "$MODEL_SHA256" ]] || {
        echo "model digest mismatch at $path (expected $MODEL_SHA256, found $actual)" >&2
        return 1
    }
}

install_model() {
    local destination="${1:-$REPOSITORY_ROOT/models/$MODEL_FILE_NAME}"
    local destination_dir temp_path quarantine_path timestamp
    local had_invalid_cache=0
    local quarantine_created=0

    destination_dir="$(dirname -- "$destination")"
    mkdir -p "$destination_dir"

    if [[ -e "$destination" ]]; then
        if verify_model "$destination" >/dev/null 2>&1; then
            echo "    Verified cached model: $destination"
            return 0
        fi
        had_invalid_cache=1
        echo "    Cached model failed verification; downloading a verified replacement." >&2
        verify_model "$destination" || true
    fi

    temp_path="$(mktemp "$destination_dir/.${MODEL_FILE_NAME}.download.XXXXXX")"
    cleanup_download() {
        rm -f -- "$temp_path"
    }
    trap cleanup_download EXIT HUP INT TERM

    echo "    Downloading pinned model revision to a temporary file..."
    "${CURL_BIN:-curl}" \
        --fail \
        --location \
        --retry "${TALKTEXT_DOWNLOAD_RETRIES:-3}" \
        --retry-all-errors \
        --connect-timeout "${TALKTEXT_CONNECT_TIMEOUT_SECONDS:-15}" \
        --output "$temp_path" \
        "$MODEL_URL"

    if ! verify_model "$temp_path"; then
        fail "downloaded model failed verification; existing model was left unchanged"
    fi

    if (( had_invalid_cache )); then
        timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
        quarantine_path="${destination}.invalid.${timestamp}.$$"
        # Preserve the rejected inode under a diagnostic name without moving
        # the live path away. Fall back to a copy on filesystems that cannot
        # create hard links, and never let a diagnostic copy block repair.
        if "${LN_BIN:-ln}" -- "$destination" "$quarantine_path"; then
            quarantine_created=1
            echo "    Hard-linked invalid model as: $quarantine_path" >&2
        elif "${CP_BIN:-cp}" -p -- "$destination" "$quarantine_path"; then
            quarantine_created=1
            echo "    Hard-link quarantine unavailable; copied invalid model as: $quarantine_path" >&2
        else
            rm -f -- "$quarantine_path"
            quarantine_path=''
            echo "    Warning: could not preserve a quarantine copy; continuing with verified replacement." >&2
        fi
    fi

    # The temporary file is created in the destination directory, so rename is
    # an atomic replacement on the same filesystem.
    if ! mv -f -- "$temp_path" "$destination"; then
        if (( quarantine_created )); then
            rm -f -- "$quarantine_path" || \
                echo "    Warning: could not remove quarantine after failed replacement: $quarantine_path" >&2
        fi
        fail "atomic model replacement failed; existing model was left unchanged"
    fi
    trap - EXIT HUP INT TERM
    echo "    Installed verified model: $destination"
}

canonical_path() {
    local path="$1"
    if [[ -e "$path" ]] && command -v realpath >/dev/null 2>&1; then
        realpath "$path"
        return
    fi
    if [[ -d "$path" ]]; then
        (CDPATH= cd -- "$path" && pwd -P)
        return
    fi

    local directory base
    directory="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    if [[ -d "$directory" ]]; then
        printf '%s/%s\n' "$(CDPATH= cd -- "$directory" && pwd -P)" "$base"
    else
        printf '%s\n' "$path"
    fi
}

is_executable_file() {
    [[ -f "$1" && -r "$1" && -x "$1" ]]
}

canonical_executable_path() {
    local path
    path="$(canonical_path "$1")"
    is_executable_file "$path" || return 1
    printf '%s\n' "$path"
}

trim_surrounding_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

configured_path() {
    local path="$1"
    local component component_index remainder
    local -a components=()

    case "$path" in
        '~')
            path="${HOME:-$path}"
            ;;
        '~/'*)
            path="${HOME:-~}/${path#\~/}"
            ;;
    esac

    [[ "$path" == /* ]] || path="$(pwd -P)/$path"

    # Match URL.standardizedFileURL: collapse separators and '.' components,
    # and resolve '..' lexically without requiring the discarded component to
    # exist on disk. Symlinks are resolved only after a candidate is selected.
    remainder="${path#/}"
    while :; do
        if [[ "$remainder" == */* ]]; then
            component="${remainder%%/*}"
            remainder="${remainder#*/}"
        else
            component="$remainder"
            remainder=''
        fi

        case "$component" in
            '' | '.')
                ;;
            '..')
                if (( ${#components[@]} )); then
                    component_index=$(( ${#components[@]} - 1 ))
                    unset "components[$component_index]"
                fi
                ;;
            *)
                components+=("$component")
                ;;
        esac

        [[ -n "$remainder" ]] || break
    done

    if (( ${#components[@]} )); then
        local IFS='/'
        printf '/%s\n' "${components[*]}"
    else
        printf '/\n'
    fi
}

resolve_backend() {
    local candidate path_entry path_remainder prefix development_root current_directory
    local -a development_roots homebrew_prefixes

    if [[ -n "$(trim_surrounding_whitespace "${TALKTEXT_WHISPER_CLI:-}")" ]]; then
        candidate="$(canonical_path "$(configured_path "$TALKTEXT_WHISPER_CLI")")"
        is_executable_file "$candidate" || fail "TALKTEXT_WHISPER_CLI is not a readable executable: $candidate"
        printf '%s\n' "$candidate"
        return
    fi

    if [[ -n "${TALKTEXT_BUNDLE_RESOURCES:-}" ]]; then
        for candidate in \
            "$TALKTEXT_BUNDLE_RESOURCES/bin/$BACKEND_EXECUTABLE" \
            "$TALKTEXT_BUNDLE_RESOURCES/$BACKEND_EXECUTABLE"; do
            if candidate="$(canonical_executable_path "$candidate")"; then
                printf '%s\n' "$candidate"
                return
            fi
        done
    fi

    # POSIX PATH treats every empty component (including a sole, leading, or
    # trailing component) as the current directory. Parse it without Bash's
    # read-array elision so the Swift and shell candidate lists stay identical.
    if [[ -n "$BACKEND_SEARCH_PATH_SET" ]]; then
        path_remainder="$BACKEND_SEARCH_PATH:"
        while [[ "$path_remainder" == *:* ]]; do
            path_entry="${path_remainder%%:*}"
            path_remainder="${path_remainder#*:}"
            [[ -n "$path_entry" ]] || path_entry="$(pwd -P)"
            path_entry="$(configured_path "$path_entry")"
            candidate="$path_entry/$BACKEND_EXECUTABLE"
            if candidate="$(canonical_executable_path "$candidate")"; then
                printf '%s\n' "$candidate"
                return
            fi
        done
    fi

    if [[ -n "$(trim_surrounding_whitespace "${HOMEBREW_PREFIX:-}")" ]]; then
        homebrew_prefixes=("$HOMEBREW_PREFIX")
    else
        homebrew_prefixes=(/opt/homebrew /usr/local)
    fi
    for prefix in "${homebrew_prefixes[@]}"; do
        [[ -n "$(trim_surrounding_whitespace "$prefix")" ]] || continue
        prefix="$(configured_path "$prefix")"
        candidate="$prefix/bin/$BACKEND_EXECUTABLE"
        if candidate="$(canonical_executable_path "$candidate")"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    current_directory="$(pwd -P)"
    development_roots=()
    if [[ -n "$(trim_surrounding_whitespace "${TALKTEXT_DEVELOPMENT_ROOT:-}")" ]]; then
        development_roots+=("$(configured_path "$TALKTEXT_DEVELOPMENT_ROOT")")
    fi
    development_roots+=(
        "$REPOSITORY_ROOT"
        "$current_directory"
        "$(dirname -- "$current_directory")"
    )

    for development_root in "${development_roots[@]}"; do
        for candidate in \
            "$development_root/.dependencies/bin/$BACKEND_EXECUTABLE" \
            "$development_root/bin/$BACKEND_EXECUTABLE"; do
            if candidate="$(canonical_executable_path "$candidate")"; then
                printf '%s\n' "$candidate"
                return
            fi
        done
    done

    candidate="${HOME:-}/.local/bin/$BACKEND_EXECUTABLE"
    if candidate="$(canonical_executable_path "$candidate")"; then
        printf '%s\n' "$candidate"
        return
    fi

    fail "$BACKEND_EXECUTABLE was not found (checked TALKTEXT_WHISPER_CLI, bundled resources, PATH, Homebrew, and development locations)"
}

normalized_backend_version() {
    local version
    version="$(trim_surrounding_whitespace "$1")"
    [[ "$version" == v* ]] && version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$version"
}

extract_backend_version() {
    local executable="$1" configured resolved output sidecar version

    configured="${TALKTEXT_WHISPER_CLI_VERSION:-}"
    if [[ -n "$(trim_surrounding_whitespace "$configured")" ]]; then
        normalized_backend_version "$configured" || true
        return
    fi

    # A sidecar filesystem entry is authoritative, including a dangling
    # symlink. Unreadable or invalid metadata fails closed instead of falling
    # through to a lower-priority version source.
    if [[ -e "${executable}.version" || -L "${executable}.version" ]]; then
        if [[ -f "${executable}.version" && -r "${executable}.version" ]]; then
            sidecar="$(<"${executable}.version")"
            normalized_backend_version "$sidecar" || true
        fi
        return
    fi

    resolved="$(canonical_path "$executable")"

    # Homebrew's whisper-cli 1.8.x does not implement --version. Its stable,
    # resolved Cellar path still records the formula version without invoking a
    # transcription or inspecting dictated content.
    if [[ "$resolved" =~ /Cellar/${BACKEND_FORMULA}/([^/]+)/ ]]; then
        if version="$(normalized_backend_version "${BASH_REMATCH[1]}")"; then
            printf '%s\n' "$version"
            return
        fi
    fi

    output="$({ "$executable" --version; } 2>&1 || true)"
    if [[ "$output" =~ [Vv][Ee][Rr][Ss][Ii][Oo][Nn][^0-9]*([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        normalized_backend_version "${BASH_REMATCH[1]}"
    fi
}

probe_backend() {
    local executable="${1:-}" help_output version flag supported_version is_supported=0
    [[ -n "$executable" ]] || executable="$(resolve_backend)"
    executable="$(canonical_path "$executable")"
    is_executable_file "$executable" || fail "backend is not a readable executable: $executable"

    if ! help_output="$({ "$executable" --help; } 2>&1)"; then
        fail "$BACKEND_EXECUTABLE --help failed; reinstall $BACKEND_FORMULA or set TALKTEXT_WHISPER_CLI"
    fi

    for flag in $BACKEND_REQUIRED_FLAGS; do
        [[ "$help_output" == *"$flag"* ]] || fail "$executable is incompatible: required option $flag is missing"
    done

    version="$(extract_backend_version "$executable")"
    if [[ -n "$version" ]]; then
        for supported_version in $BACKEND_SUPPORTED_VERSIONS; do
            if [[ "$version" == "$supported_version" ]]; then
                is_supported=1
                break
            fi
        done
        (( is_supported )) || fail "$BACKEND_EXECUTABLE $version is unsupported; install one of: $BACKEND_SUPPORTED_VERSIONS"
        printf 'path=%s\nversion=%s\ncompatibility=version-and-capability-verified\n' "$executable" "$version"
    else
        fail "$BACKEND_EXECUTABLE did not report a version; set TALKTEXT_WHISPER_CLI_VERSION after verifying compatibility, or install $BACKEND_FORMULA with Homebrew"
    fi
}

usage() {
    cat <<'USAGE'
Usage: scripts/dependency-tool.sh COMMAND [PATH]

Commands:
  install-model [PATH]   Atomically download and verify the pinned model.
  verify-model [PATH]    Verify model size, format, and SHA-256.
  resolve-backend        Print the resolved whisper-cli path.
  probe-backend [PATH]   Verify backend readability, version, and required flags.
  manifest               Print the dependency manifest path.
USAGE
}

command_name="${1:-}"
case "$command_name" in
    install-model)
        install_model "${2:-$REPOSITORY_ROOT/models/$MODEL_FILE_NAME}"
        ;;
    verify-model)
        verify_model "${2:-$REPOSITORY_ROOT/models/$MODEL_FILE_NAME}"
        ;;
    resolve-backend)
        resolve_backend
        ;;
    probe-backend)
        probe_backend "${2:-}"
        ;;
    manifest)
        printf '%s\n' "$MANIFEST_PATH"
        ;;
    -h|--help|help|'')
        usage
        ;;
    *)
        usage >&2
        fail "unknown command: $command_name"
        ;;
esac
