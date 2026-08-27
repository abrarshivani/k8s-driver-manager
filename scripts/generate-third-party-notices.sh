#!/usr/bin/env bash
# Copyright (c) NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Writes THIRD_PARTY_NOTICES.md for the Go modules linked into ./cmd/... .

set -euo pipefail

OUTPUT="${OUTPUT:-THIRD_PARTY_NOTICES.md}"
LICENSES_DIR="${LICENSES_DIR:-.licenses-cache}"
MULTI_ARCH_MK="${MULTI_ARCH_MK:-deployments/container/multi-arch.mk}"
MODULES_TXT="${MODULES_TXT:-vendor/modules.txt}"

PACKAGES=("./cmd/...")

# Must match the released image platforms; verify_platform_matrix fails on drift
# so a new target cannot silently produce an incomplete file.
PLATFORMS=(
    "linux/amd64"
    "linux/arm64"
)

die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

# Licenses that are themselves Markdown close a fixed ``` fence early and invert
# every block after it, so open with one backtick more than the file's longest run.
fence_for() {
    local file="$1" longest_backtick_run fence_width
    # -a: a license holding a NUL byte would otherwise print "Binary file ...
    # matches" instead of the matches, on stdout or stderr depending on the grep.
    longest_backtick_run=$(LC_ALL=C grep -oaE '`+' "${file}" 2>/dev/null \
        | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' || true)
    fence_width=$(( longest_backtick_run + 1 ))
    (( fence_width < 3 )) && fence_width=3
    printf '%*s' "${fence_width}" '' | tr ' ' '`'
}

check_prerequisites() {
    command -v go >/dev/null 2>&1 || die "go is not installed."

    # Probe by running it, not with -x: a host-built binary bind-mounted into a
    # Linux container passes -x but cannot exec.
    if ./bin/go-licenses --help >/dev/null 2>&1; then
        GO_LICENSES="${PWD}/bin/go-licenses"
    elif command -v go-licenses >/dev/null 2>&1; then
        GO_LICENSES="$(command -v go-licenses)"
    else
        die "go-licenses is not installed or cannot run on this host." \
            "If ./bin/go-licenses exists it was built for another platform:" \
            "remove it, then run 'make -C deployments/devel install-tools'."
    fi

    local required_file
    for required_file in "${MULTI_ARCH_MK}" "${MODULES_TXT}" "${LICENSE_OVERRIDES}"; do
        [[ -f "${required_file}" ]] \
            || die "${required_file} not found — run 'make third-party-notices' from the repo root."
    done

    LOCAL_MODULE=$(go list -m 2>/dev/null || true)
    [[ -n "${LOCAL_MODULE}" ]] || die "could not determine local module path via 'go list -m'."

    # vendor/ keeps this offline. CGO off matches the released binaries and lets
    # go-licenses cross-list without a C toolchain.
    export GOFLAGS="-mod=vendor"
    export CGO_ENABLED=0
}

verify_platform_matrix() {
    local expected actual
    expected=$(sed -n 's/^DOCKER_BUILD_PLATFORM_OPTIONS[[:space:]]*?*=[[:space:]]*--platform=//p' \
        "${MULTI_ARCH_MK}" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
    [[ -n "${expected}" ]] \
        || die "could not read DOCKER_BUILD_PLATFORM_OPTIONS from ${MULTI_ARCH_MK}."

    actual=$(printf '%s\n' "${PLATFORMS[@]}" | LC_ALL=C sort -u)
    [[ "${expected}" == "${actual}" ]] || die \
        "the PLATFORMS matrix is out of sync with ${MULTI_ARCH_MK}." \
        "Update the PLATFORMS array in scripts/generate-third-party-notices.sh to match the released targets." \
        "  matrix (PLATFORMS): $(echo "${actual}" | paste -sd ' ' -)" \
        "  image platforms:    $(echo "${expected}" | paste -sd ' ' -)"
}

prepare_workspace() {
    # Rebuilt each run. Guard the override: '', '/', '.' or '..' would make this fatal.
    case "${LICENSES_DIR}" in
        ""|"/"|"."|"..")
            die "refusing to 'rm -rf' unsafe LICENSES_DIR='${LICENSES_DIR}'."
            ;;
    esac
    rm -rf "${LICENSES_DIR}"
    mkdir -p "${LICENSES_DIR}"

    # Explicit templates: macOS mktemp ignores TMPDIR without one.
    local workspace_template="${TMPDIR:-/tmp}/k8s-driver-manager-notices"
    SAVE_ROOT="$(mktemp -d "${workspace_template}.XXXXXX")"
    COMBINED_CSV="$(mktemp "${workspace_template}-csv.XXXXXX")"
    INDEX_FILE="$(mktemp "${workspace_template}-idx.XXXXXX")"

    # Composed beside ${OUTPUT}, not under TMPDIR, so the last step is a
    # same-filesystem rename(2) rather than a copy-then-unlink.
    mkdir -p "$(dirname "${OUTPUT}")"
    OUT_TMP="$(mktemp "${OUTPUT}.XXXXXX")"
    trap 'rm -rf "${SAVE_ROOT}"; rm -f "${COMBINED_CSV}" "${INDEX_FILE}" "${OUT_TMP}"' EXIT
}

collect_runtime() {
    local platform goos goarch save_dir

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"
        log "Collecting licenses for ${goos}/${goarch}..."

        save_dir="${SAVE_ROOT}/${goos}_${goarch}"

        # Only the local module is ignored. go-licenses already omits the
        # standard library, and --ignore matches on plain STRING prefixes, not
        # path segments: passing stdlib top-level names silently drops every
        # dependency starting with those letters — the token "go" (from go/ast,
        # go/build) removes golang.org/x/*, google.golang.org/*, gopkg.in/* and
        # go.yaml.in/*, which here is 13 of the 70 vendored modules. Keep this
        # list minimal and never add a short, generic prefix.
        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" save "${PACKAGES[@]}" \
            --save_path="${save_dir}" \
            --force \
            --ignore="${LOCAL_MODULE}"

        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${PACKAGES[@]}" \
            --ignore="${LOCAL_MODULE}" \
            >> "${COMBINED_CSV}"

        merge_licenses "${save_dir}" "${LICENSES_DIR}"
    done
}

# Union into the shared tree: text is identical across platforms so overwrites
# are no-ops. Keep the chmod even though vendor/ is writable — 'go-licenses save'
# preserves source permissions, and a read-only file would make the next
# platform's copy fail.
merge_licenses() {
    cp -R "$1/." "$2/"
    chmod -R u+w "$2"
}

# One row per package, joining licenses rather than picking one: go-licenses
# emits a row per recognized license, so key-only dedup would hide a module's
# second license behind its first. Key-only dedup is also non-deterministic —
# BSD sort keeps the first input row, GNU sort applies a whole-line tiebreak —
# so sort whole lines first.
collapse_index() {
    LC_ALL=C sort -u "$1" | awk -F, '
        {
            pkg = $1
            if (!(pkg in url)) { url[pkg] = $2; order[++n] = pkg }
            if (!((pkg SUBSEP $3) in seen)) {
                seen[pkg SUBSEP $3] = 1
                # Count, do not test "pkg in lic". mawk and busybox awk
                # instantiate the assignment target before evaluating the
                # right-hand side, so that test is already true on the first row
                # and every license comes out prefixed with " / ". BWK awk (the
                # macOS default) and gawk do not, so the split is by awk
                # implementation, not by OS — and mawk is /usr/bin/awk on stock
                # Debian and Ubuntu. This form is correct on all of them.
                lic[pkg] = (cnt[pkg]++ ? lic[pkg] " / " : "") $3
            }
        }
        END { for (i = 1; i <= n; i++) print order[i] "," url[order[i]] "," lic[order[i]] }
    '
}

# In vendor mode go-licenses reports a URL into this repo at HEAD, which stops
# describing released content once main moves and names our copy rather than
# upstream, so append the dependency path and version from modules.txt. The
# verified upstream location comes from scripts/license-urls.tsv.
# Longest-prefix match: a license may sit below the module root.
annotate_modules() {
    awk -v modfile="${MODULES_TXT}" '
        BEGIN {
            FS = OFS = ","
            while ((getline line < modfile) > 0) {
                if (line !~ /^# /) continue
                split(line, f, " ")
                # "# <path> <version>", optionally "=> <path> <version>" for a
                # replace. The replacement is what is actually vendored, so it
                # is what the notices file must name. A filesystem replacement
                # cannot be reliably attributed, so stop rather than misstate it.
                if (f[4] == "=>" || f[3] == "=>") {
                    r = (f[4] == "=>") ? 5 : 4
                    if (f[r + 1] == "") {
                        print "ERROR: " modfile " replaces " f[2] " with a local path;" > "/dev/stderr"
                        print "teach scripts/generate-third-party-notices.sh how to attribute it." > "/dev/stderr"
                        exit 1
                    }
                    mods[++m] = f[2]
                    disp[f[2]] = f[r]
                    ver[f[2]] = f[r + 1]
                } else {
                    mods[++m] = f[2]
                    disp[f[2]] = f[2]
                    ver[f[2]] = f[3]
                }
            }
            close(modfile)
            # A read error makes getline return -1 and the loop never runs,
            # which would label every entry "unknown" without failing.
            if (m == 0) {
                print "ERROR: no module lines read from " modfile > "/dev/stderr"
                exit 1
            }
        }
        {
            best = ""
            for (i = 1; i <= m; i++) {
                mp = mods[i]
                if (($1 == mp || index($1, mp "/") == 1) && length(mp) > length(best)) best = mp
            }
            print $0, (best == "" ? "unknown" : disp[best]), (best == "" ? "unknown" : ver[best])
        }
    '
}

build_index() {
    log "Generating dependency index..."
    collapse_index "${COMBINED_CSV}" | annotate_modules > "${INDEX_FILE}"

    [[ -s "${INDEX_FILE}" ]] \
        || die "go-licenses produced no entries for ${PACKAGES[*]} — refusing to write empty notices file."

    # An empty field would also render as "Unknown" via the :- fallback in the
    # table, so catch it here rather than letting it reach the document.
    if cut -d, -f3 "${INDEX_FILE}" | LC_ALL=C grep -qE '^$|(^| / )Unknown( / |$)'; then
        die "go-licenses could not identify a license for some dependencies." \
            "Check the entries reported as Unknown before committing the file."
    fi

    # Dependencies are resolved offline from vendor/modules.txt, so "unknown" here
    # means a package under vendor/ that no module line covers.
    if cut -d, -f4 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "some entries could not be matched to a module in ${MODULES_TXT}." \
            "Run 'make vendor' so modules.txt covers everything under vendor/."
    fi

    if cut -d, -f5 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "some entries could not be matched to a version in ${MODULES_TXT}." \
            "Run 'make vendor' so modules.txt covers everything under vendor/."
    fi

    check_override_coverage "${INDEX_FILE}"
}

# A dropped dependency would otherwise leave its row in LICENSE_OVERRIDES
# silently asserting a license for a package no longer shipped.
check_override_coverage() {
    local index="$1" override_package
    while IFS=$'\t' read -r override_package _ _; do
        case "${override_package}" in
            ''|'#'*) continue ;;
        esac
        LC_ALL=C cut -d, -f1 "${index}" | LC_ALL=C grep -qFx "${override_package}" \
            || die "${LICENSE_OVERRIDES} has a row for ${override_package}, which is not in the generated index." \
                   "Remove that row from ${LICENSE_OVERRIDES} — the dependency was likely dropped."
    done < "${LICENSE_OVERRIDES}"
}

# License-bearing files, sorted. Filter by name: for restricted licenses
# 'go-licenses save' copies the whole module source, which does not belong here.
license_files_for() {
    local search_dir="$1" license_file file_basename
    [[ -d "${search_dir}" ]] || return 0
    while IFS= read -r -d '' license_file; do
        file_basename="$(basename "${license_file}")"
        # Exclude source files: the name pattern below also matches source files
        # that merely start with a license-shaped header, e.g. a Go file named
        # license.go beginning with a copyright block.
        case "${file_basename}" in
            *.go|*.c|*.h|*.s|*.py|*.sh|*.java|*.ts|*.js) continue ;;
        esac
        # LC_ALL=C for the same reason it is on every sort here: under a Turkish
        # locale glibc does not fold I to i, so this would stop matching LICENSE
        # and every section would silently render "License text unavailable".
        if printf '%s' "${file_basename}" \
            | LC_ALL=C grep -qiE '^(licen[cs]e|notice|copying|copyright|authors|patents)([-._].*)?$'; then
            printf '%s\n' "${license_file}"
        fi
    done < <(find "${search_dir}" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
}

LICENSE_URLS="${LICENSE_URLS:-scripts/license-urls.tsv}"
LICENSE_OVERRIDES="${LICENSE_OVERRIDES:-scripts/license-overrides.tsv}"
VENDOR_DIR="${VENDOR_DIR:-vendor}"

# Separate from check_prerequisites: scripts/verify-license-urls.sh reuses the
# collection stages to discover which license files the document will link, and
# it is the command that produces this map, so it must run without it.
require_url_map() {
    [[ -f "${LICENSE_URLS}" ]] \
        || die "${LICENSE_URLS} not found." \
               "Run 'make third-party-notices-urls' (needs network) and commit the result."
}

# A single license file can bundle more than one license, which go-licenses
# reports as whichever one it scores highest; LICENSE_OVERRIDES corrects the
# identifier by hand without touching the license text, which is unaffected.
license_identifier_for() {
    local package="$1" default_identifier="$2" override_identifier
    override_identifier="$(LC_ALL=C awk -F'\t' -v pkg="${package}" \
        '$1 == pkg { print $2; exit }' "${LICENSE_OVERRIDES}")"
    printf '%s' "${override_identifier:-${default_identifier}}"
}

# The first enclosing directory holding a license file wins, which is how
# go-licenses attributes them.
license_dir_within_module() {
    local module="$2" dir="$1" relative
    while :; do
        if [[ -n "$(license_files_for "${VENDOR_DIR}/${dir}")" ]]; then
            relative="${dir#"${module}"}"
            printf '%s' "${relative#/}"
            return 0
        fi
        [[ "${dir}" == "${module}" ]] && return 1
        [[ "${dir}" != */* ]] && return 1
        dir="${dir%/*}"
    done
}

location_for() {
    local url
    url="$(LC_ALL=C awk -F'\t' -v m="$1" -v v="$2" -v p="$3" \
        '$1 == m && $2 == v && $3 == p { print $4; found = 1; exit }
         END { exit !found }' "${LICENSE_URLS}")" || return 1
    [[ -n "${url}" ]] || return 1
    printf '%s' "${url}"
}

# Mirrors how the License column joins identifiers.
location_cell() {
    local package="$1" module="$2" version="$3"
    local relative_license_dir license_file_name license_path url cell="" license_file governing_dir
    relative_license_dir="$(license_dir_within_module "${package}" "${module}")" \
        || die "no license file found for ${package} under ${VENDOR_DIR}/${module}." \
               "Run 'make vendor' and re-run."
    governing_dir="${VENDOR_DIR}/${module}${relative_license_dir:+/${relative_license_dir}}"
    while IFS= read -r license_file; do
        [[ -z "${license_file}" ]] && continue
        license_file_name="$(basename "${license_file}")"
        license_path="${relative_license_dir:+${relative_license_dir}/}${license_file_name}"
        url="$(location_for "${module}" "${version}" "${license_path}")" \
            || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${license_path}." \
                   "Run 'make third-party-notices-urls' (needs network) and commit the result."
        cell="${cell:+${cell} / }[${license_file_name}](${url})"
    done < <(license_files_for "${governing_dir}")
    [[ -n "${cell}" ]] || die "no license file for ${package} under ${governing_dir}." \
                              "Run 'make vendor' and re-run."
    printf '%s' "${cell}"
}

emit_index_table() {
    local index="$1" package _ license module version location license_identifier
    printf '| Package | Version | License | Location |\n'
    printf '|---------|---------|---------|----------|\n'

    while IFS=, read -r package _ license module version; do
        [[ -z "${package}" ]] && continue
        location="$(location_cell "${package}" "${module}" "${version}")"
        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | %s | %s | %s |\n' \
            "${package}" "${version:-unknown}" \
            "${license_identifier}" "${location}"
    done < "${index}"
}

emit_sections() {
    local index="$1"
    local package _ license module version files license_file fence relative_license_dir license_file_name url governing_dir license_identifier

    while IFS=, read -r package _ license module version; do
        [[ -z "${package}" ]] && continue

        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        printf '### %s\n\n' "${package}"
        printf '* Version: %s\n' "${version:-unknown}"
        printf '* License: %s\n\n' "${license_identifier}"

        relative_license_dir="$(license_dir_within_module "${package}" "${module}")" \
            || die "no license file found for ${package} under ${VENDOR_DIR}/${module}." \
                   "Run 'make vendor' and re-run."
        governing_dir="${VENDOR_DIR}/${module}${relative_license_dir:+/${relative_license_dir}}"

        files=()
        while IFS= read -r license_file; do
            [[ -n "${license_file}" ]] && files+=("${license_file}")
        done < <(license_files_for "${governing_dir}")

        if (( ${#files[@]} == 0 )); then
            printf 'License text unavailable. See upstream source for the full license.\n'
        else
            for license_file in "${files[@]}"; do
                license_file_name="$(basename "${license_file}")"
                url="$(location_for "${module}" "${version}" "${relative_license_dir:+${relative_license_dir}/}${license_file_name}")" \
                    || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${relative_license_dir:+${relative_license_dir}/}${license_file_name}." \
                           "Run 'make third-party-notices-urls' (needs network) and commit the result."
                fence="$(fence_for "${license_file}")"
                printf '#### %s\n\n' "${license_file_name}"
                printf '<%s>\n\n' "${url}"
                printf '%stext\n' "${fence}"
                cat "${license_file}"
                echo
                printf '%s\n' "${fence}"
                echo
            done
        fi
        echo
    done < "${index}"
}

compose_document() {
    require_url_map
    log "Composing ${OUTPUT}..."
    # Build in a temp file next to the output and rename it into place. The
    # destination is only ever replaced whole, so a failure part way through
    # leaves the previous file intact rather than truncated in a developer's
    # worktree. Copying instead would truncate the destination up front.
    {
        cat <<'EOF'
# Third-Party Notices

NVIDIA Driver Upgrade Manager for Kubernetes

This file lists every third-party dependency that Driver Upgrade Manager
redistributes, along with the verbatim text of each dependency's license. In
particular, this covers all **Go modules** statically linked into the commands
under `cmd/`, resolved as the union across every released image platform. The
`driver-manager` and `vfio-manage` commands ship in the `k8s-driver-manager`
image. Go standard library packages are excluded; they are covered by the
license of the Go distribution itself.

Each dependency is listed with the version redistributed and a link to the
license file in that version's upstream source. Every link was verified by
fetching it and comparing its contents against the copy vendored here, so each
one resolves to the same license text reproduced below. Modules that no command
under `cmd/` links are not listed; those are vendored only for this module's own
tests and build tooling.

The `k8s-driver-manager` image uses `nvcr.io/nvidia/distroless/cc` as a base
image. All of the OSS packages and source included in this image can be found at
<https://developer.nvidia.com/w/distroless-oss/index.html>. A statically
compiled busybox binary is added to the image, which is licensed under GPLv2.

## Dependency Index

EOF
        emit_index_table "${INDEX_FILE}"

        cat <<'EOF'

## License Texts

EOF
        emit_sections "${INDEX_FILE}"
    } > "${OUT_TMP}"
    # mktemp creates 0600 and the committed file should be world-readable. Set
    # the mode before the rename so the document is never briefly 0600 at its
    # final path.
    chmod 644 "${OUT_TMP}"
    mv -f "${OUT_TMP}" "${OUTPUT}"
}

main() {
    check_prerequisites
    verify_platform_matrix
    prepare_workspace

    collect_runtime
    build_index
    compose_document

    # Rows are per license-bearing directory, not per module: a module that
    # ships a second license below its root contributes more than one row.
    local count
    count=$(wc -l < "${INDEX_FILE}" | tr -d ' ')
    log "Wrote ${OUTPUT} (${count} Go dependencies)"
}

# Sourced by the tests and by scripts/verify-license-urls.sh, which reuse these
# functions without the side effects of a full run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
