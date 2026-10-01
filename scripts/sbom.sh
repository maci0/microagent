#!/bin/sh
# What a release ships, as an SPDX 2.3 inventory: the published assets with the
# digest of each, the one package they are, and every third-party pin the
# repository declares, each named with the manifest that declares it. A consumer
# or a vulnerability scanner reading the release page learns from the file that
# the binaries bundle no third-party code and link no libc, and which packages
# the repository does use and in what role, rather than inferring it from the
# size of the binary.
#
# The file describes dist/ as it stands, so it names the assets
# `make release-assets` produced and nothing else, and it is written into that
# directory so `make checksums` gives it a sidecar beside the assets'. The
# digests come from SHA256_CMD, the command the Makefile decided to hash with,
# passed in as the environment so a host without GNU coreutils writes an
# inventory that agrees with the sidecars it sits beside.
#
# The dist directory arrives as an argument so the Makefile stays the one place
# a release path is written down.
#
# The locale and timezone are pinned here rather than left to the caller, because
# two `sort`s below decide the order the pins and the files are written in: under
# a locale whose collation puts `_` before `a`, or a case-insensitive one that
# orders ASCII by case, the same dist/ and the same manifests produce a document
# whose bytes depend on the machine that generated it. The Makefile exports the
# same pair for every other recipe, and this script is also run by hand, so the
# guarantee cannot live only there.
LC_ALL=C
TZ=UTC
export LC_ALL TZ
set -eu

: "${1:?usage: sbom.sh <dist directory>}"
: "${SHA256_CMD:?SHA256_CMD is required}"
: "${SHA1_CMD:?SHA1_CMD is required}"

dist="$1"
# The two manifests the pins are read from, in the order they are listed in the
# inventory: a linter a push is gated with, then the benchmark harness's whole
# tree. The paths arrive as arguments with the dist directory rather than being
# written here, for the reason the directory is: one spelling of each.
shift
manifests="$*"

for file in $manifests; do
	test -f "$file" || { echo "no $file, so the inventory would omit pins the tree declares" >&2; exit 1; }
done

# The assets, by name, from the files rather than from a tag: what a release
# publishes is what is in this directory, and whether the build behind it names
# the version the tag does is `make check-assets`' question.
assets=
asset_count=0
for path in "$dist"/microagent-v*; do
	name="${path##*/}"
	# A previous run's inventory, and the sidecar beside it, are output of this
	# script rather than assets of the release. The glob is `microagent-v*`,
	# which the document's own name matches, so a second `make sbom` over a
	# dist/ that already holds one reads its own last output back as an asset:
	# the document then names a file that was never published, hashes it into
	# the package verification code, and every run after the first disagrees
	# with the one before it. `make release-assets` empties dist/ so a tag never
	# reaches that, but the target is run by hand over a build that is already
	# there, and a document that changes each time it is regenerated describes
	# nothing.
	case "$name" in
	*.sha256 | *.tmp | *.spdx.json) continue ;;
	esac
	test -f "$path" || continue
	# A name outside this set is a path a JSON string would have to escape, and
	# an escaped one is a name no scanner reads back as the asset it describes.
	case "$name" in
	*[!A-Za-z0-9._-]*)
		echo "$name is not a name this inventory can carry verbatim, so it is left out rather than written as an escape sequence" >&2
		exit 1
		;;
	esac
	assets="$assets $name"
	asset_count=$((asset_count + 1))
done
test -n "$assets" || {
	echo "no tagged assets in $dist/, so there is no release to describe: run 'make release-assets TAG=v0.2.0' first" >&2
	exit 2
}

first="${assets# }"
tag="${first#microagent-}"
tag="${tag%%-*}"
# build.zig.zon carries no v and a tag does, so the version the package and
# the download location name is the tag's second field. The file itself is
# named after the tag, because the name a release publishes is the one the
# assets beside it carry.
version="${tag#v}"
commit="$(git log -1 --format=%H)" || {
	echo "the commit this inventory describes could not be read, so the document has no unique name" >&2
	exit 1
}
test -n "$commit" || { echo "this tree has no commit, so there is nothing for the inventory to name" >&2; exit 1; }
copyright="$(sed -n 's/^\(Copyright .*\)$/\1/p' LICENSE | head -1)"
test -n "$copyright" || { echo "LICENSE names no copyright line, so the inventory would carry NOASSERTION where the grant is" >&2; exit 1; }
# The grant, as the SPDX identifier the document records, read out of LICENSE
# rather than written here: an inventory that claims MIT over a relicensed tree
# is a document a scanner and a reader both believe, and the reader is the one
# it misleads. An identifier this script does not know stops the release, so a
# relicensing is a line added to the list below and nothing else to find.
license_named="$(sed -n '1{s/[[:space:]]*[Ll]icen[cs]e[[:space:]]*$//;p;}' LICENSE)"
license=
# Case folded with the locale's own ranges on both sides, so a LICENSE whose
# first line reads "mit" or "Mit" is the identifier the list spells rather than
# a release that stops on a spelling.
license_folded="$(printf '%s' "$license_named" | tr '[:upper:]' '[:lower:]')"
for identifier in MIT Apache-2.0 ISC BSD-2-Clause BSD-3-Clause MPL-2.0 Unlicense Zlib CC0-1.0; do
	folded="$(printf '%s' "$identifier" | tr '[:upper:]' '[:lower:]')"
	if [ "$license_folded" = "$folded" ]; then
		license="$identifier"
		break
	fi
done
test -n "$license" || {
	echo "LICENSE names '$license_named', which is no SPDX identifier this script writes" >&2
	exit 1
}
# The creation time is SOURCE_DATE_EPOCH when the environment names one, and the
# clock otherwise. `check-reproducible` varies SOURCE_DATE_EPOCH between its two
# builds of every target, and the reproducible-builds convention is that a
# toolchain stamps that value into the artifacts it writes; a document carrying
# the wall clock instead means regenerating the inventory over an unchanged
# dist/ yields different bytes, so a checksum published beside it describes a
# file nobody can produce again. The conversion is spelled for both date
# implementations: GNU coreutils takes `-d @<epoch>` and BSD takes `-r <epoch>`,
# and a host with neither of those fails the release rather than falling back to
# a clock, because a silent fallback is the nondeterminism this removes.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	case "$SOURCE_DATE_EPOCH" in
		*[!0-9]* | '')
			echo "SOURCE_DATE_EPOCH is '$SOURCE_DATE_EPOCH', which is not a Unix timestamp" >&2
			exit 1
			;;
	esac
	if created="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
		:
	elif created="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
		:
	else
		echo "no date on this host converts a Unix timestamp, so the inventory cannot honor SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" >&2
		exit 1
	fi
else
	created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# One line per pin, the manifest that declares it last, deduplicated on the pin
# so a package both manifests name is described once, by the first of them.
# The third field is what the manifest's own `via` comment says the pin is
# there for, and it is read rather than written because the two sets are a
# linter's two packages and the benchmark harness's ninety: a document that
# called boto3 a linter would describe a role nothing in this tree gives it,
# and a role read out of the lock cannot drift from the lock.
pins="$(
	for manifest in $manifests; do
		awk -v manifest="$manifest" '
			function flush() { if (cur != "") print cur "|" manifest "|" parents; cur = ""; parents = ""; wrapped = 0 }
			/^[A-Za-z0-9_.-]+==/ { flush(); cur = $1; next }
			cur == "" { next }
			# `    # via <parent>` names the parents on the comment line itself.
			/^[[:space:]]*# via[[:space:]]+/ {
				wrapped = 0
				for (i = 3; i <= NF; i++) parents = parents " " $i
				next
			}
			# `    # via` with nothing after it puts the parents on the lines below.
			/^[[:space:]]*# via[[:space:]]*$/ { wrapped = 1; next }
			wrapped && /^[[:space:]]*#   [^ ]/ { for (i = 1; i <= NF; i++) if ($i != "#") parents = parents " " $i; next }
			END { flush() }
		' "$manifest"
	done | sort -u -t'|' -k1,1
)"
test -n "$pins" || { echo "no manifest names a package, so the inventory would claim the tree pins nothing" >&2; exit 1; }
# The count is taken here rather than in the closing report, where a pipeline
# inside a command substitution hides whether either half of it failed.
pin_count="$(printf '%s\n' "$pins" | wc -l)"

# The digest of one file, through the command the sidecars beside these assets
# were written with. SHA256_CMD is that command, which the Makefile resolved
# before it got here, so a host without GNU coreutils hashes the way its
# sidecars were written. It is a word list rather than a command with a flag,
# because on such a host it is "shasum -a 256" and three words.
hash_command="$SHA256_CMD"
test -n "$hash_command" || {
	echo "SHA256_CMD is empty, so the digests this inventory records cannot be read" >&2
	exit 2
}
hash() {
	width=$1
	shift
	output=$("$@") || return $?
	value=${output%% *}
	[ "${#value}" -eq "$width" ] || return 1
	case "$value" in *[!A-Fa-f0-9]*) return 1 ;; esac
	printf '%s\n' "$value"
}

digest() {
	path="$1"
	# because: hash_command is a word list, and "shasum -a 256" is three of them
	# shellcheck disable=SC2086
	set -- $hash_command
	hash 64 "$@" "$path"
}

# SPDX 2.3 requires a package whose files were analyzed to carry a
# verification code, and a consumer checking the document against the files it
# names has nothing to recompute without one. The code is the SHA1 of the
# SHA1 digests of the files, concatenated in file-name order, so the digest is
# of digests and the outer hash is the one the format names. SHA1 is specified
# here and is not the digest the sidecars use: a package manager recomputes this
# one with a SHA1 implementation, and a SHA256 code would be no code at all. It
# arrives as SHA1_CMD, the command the Makefile resolved, for the reason
# SHA256_CMD does: one place decides which hashing command this host has.
sha1_command="$SHA1_CMD"
test -n "$sha1_command" || {
	echo "SHA1_CMD is empty, so the SPDX verification code cannot be computed" >&2
	exit 2
}
sha1() {
	# because: sha1_command is a word list, and "shasum -a 1" is three of them
	# shellcheck disable=SC2086
	set -- $sha1_command
	hash 40 "$@"
}
file_digests=
# because: assets is a space-separated list and each name is one word
# shellcheck disable=SC2086
for name in $(printf '%s\n' $assets | sort); do
	file_digest=$(sha1 < "$dist/$name")
	file_digests="$file_digests$file_digest"
done
verification_code="$(printf '%s' "$file_digests" | sha1)"
test -n "$verification_code" || {
	echo "the verification code could not be computed, so the inventory would carry none where SPDX requires one" >&2
	exit 1
}

out="$dist/microagent-$tag.spdx.json"
{
	printf '{\n'
	printf '  "spdxVersion": "SPDX-2.3",\n'
	printf '  "dataLicense": "CC0-1.0",\n'
	printf '  "SPDXID": "SPDXRef-DOCUMENT",\n'
	printf '  "name": "microagent-%s",\n' "$version"
	printf '  "documentNamespace": "https://github.com/maci0/microagent/spdx/microagent-%s-%s",\n' "$version" "$commit"
	printf '  "creationInfo": {\n'
	printf '    "created": "%s",\n' "$created"
	printf '    "creators": [\n'
	printf '      "Tool: scripts/sbom.sh",\n'
	printf '      "Organization: microagent (https://github.com/maci0/microagent)"\n'
	printf '    ]\n'
	printf '  },\n'
	printf '  "packages": [\n'
	printf '    {\n'
	printf '      "SPDXID": "SPDXRef-Package-microagent",\n'
	printf '      "name": "microagent",\n'
	printf '      "versionInfo": "%s",\n' "$version"
	printf '      "downloadLocation": "https://github.com/maci0/microagent/releases/tag/v%s",\n' "$version"
	printf '      "filesAnalyzed": true,\n'
	printf '      "packageVerificationCode": {\n'
	printf '        "packageVerificationCodeValue": "%s"\n' "$verification_code"
	printf '      },\n'
	printf '      "licenseConcluded": "%s",\n' "$license"
	printf '      "licenseDeclared": "%s",\n' "$license"
	printf '      "copyrightText": "%s",\n' "$copyright"
	printf '      "primaryPackagePurpose": "APPLICATION",\n'
	printf '      "comment": "The published assets. The binaries link no libc and carry no third-party code: build.zig.zon declares no dependency, and the files listed below are the whole of what a release is."\n'
	printf '    }'
	# A here-document rather than a pipe: a pipe would run the loop in a
	# subshell, and the separator each entry after the first needs is state.
	while IFS='|' read -r pin manifest via; do
		name="${pin%%==*}"
		pin_version="${pin#*==}"
		# The role is what the manifest records, in each of the three shapes a
		# `via` comment takes. A pin the manifest names no parent for says so
		# rather than being described as a linter or the adapter, which is the
		# one role nothing in this tree can support from an absent record.
		case "$via" in
			" -r "*)
				role="Declared in $manifest, which uv resolves directly for the gate or the benchmark, and in no published asset."
				;;
			" "*)
				role="Pinned in $manifest as a dependency of${via}, resolved by uv and asked for by nothing here, and in no published asset."
				;;
			*)
				role="Pinned in $manifest, which records no parent for it, and in no published asset."
				;;
		esac
		printf ',\n'
		printf '    {\n'
		printf '      "SPDXID": "SPDXRef-Package-%s-%s",\n' "$name" "$pin_version"
		printf '      "name": "%s",\n' "$name"
		printf '      "versionInfo": "%s",\n' "$pin_version"
		printf '      "downloadLocation": "NOASSERTION",\n'
		printf '      "filesAnalyzed": false,\n'
		printf '      "licenseConcluded": "NOASSERTION",\n'
		printf '      "licenseDeclared": "NOASSERTION",\n'
		printf '      "primaryPackagePurpose": "OTHER",\n'
		printf '      "externalRefs": [\n'
		printf '        {\n'
		printf '          "referenceCategory": "PACKAGE-MANAGER",\n'
		printf '          "referenceType": "purl",\n'
		printf '          "referenceLocator": "pkg:pypi/%s@%s"\n' "$name" "$pin_version"
		printf '        }\n'
		printf '      ],\n'
		printf '      "comment": "%s"\n' "$role"
		printf '    }'
	done <<EOF
$pins
EOF
	printf '\n  ],\n'
	printf '  "files": [\n'
	separator=
	for name in $assets; do
		printf '%s' "$separator"
		printf '    {\n'
		printf '      "SPDXID": "SPDXRef-File-%s",\n' "$name"
		printf '      "fileName": "%s",\n' "$name"
		printf '      "checksums": [\n'
		# The digest is read into a variable with the command's own exit status
		# rather than inside the printf: a command substitution's failure is
		# discarded by the printf that reads it, so an unreadable asset wrote a
		# document recording an empty checksumValue rather than failing the
		# release that reads it. A bare assignment is the statement `set -e`
		# exits on, and the empty test covers a hash command that printed
		# nothing and succeeded.
		asset_digest="$(digest "$dist/$name")"
		test -n "$asset_digest" || {
			echo "the digest of $name could not be read, so the inventory would record no checksum for it" >&2
			exit 1
		}
		printf '        {\n'
		printf '          "algorithm": "SHA256",\n'
		printf '          "checksumValue": "%s"\n' "$asset_digest"
		printf '        }\n'
		printf '      ],\n'
		printf '      "licenseConcluded": "%s",\n' "$license"
		printf '      "licenseDeclared": "%s",\n' "$license"
		printf '      "copyrightText": "%s"\n' "$copyright"
		printf '    }'
		separator=,
	done
	printf '\n  ],\n'
	printf '  "relationships": [\n'
	printf '    {\n'
	printf '      "spdxElementId": "SPDXRef-DOCUMENT",\n'
	printf '      "relatedSpdxElement": "SPDXRef-Package-microagent",\n'
	printf '      "relationshipType": "DESCRIBES"\n'
	printf '    }'
	for name in $assets; do
		printf ',\n'
		printf '    {\n'
		printf '      "spdxElementId": "SPDXRef-Package-microagent",\n'
		printf '      "relatedSpdxElement": "SPDXRef-File-%s",\n' "$name"
		printf '      "relationshipType": "CONTAINS"\n'
		printf '    }'
	done
	while IFS='|' read -r pin _; do
		name="${pin%%==*}"
		pin_version="${pin#*==}"
		printf ',\n'
		printf '    {\n'
		printf '      "spdxElementId": "SPDXRef-Package-%s-%s",\n' "$name" "$pin_version"
		printf '      "relatedSpdxElement": "SPDXRef-Package-microagent",\n'
		printf '      "relationshipType": "BUILD_DEPENDENCY_OF"\n'
		printf '    }'
	done <<EOF
$pins
EOF
	printf '\n  ],\n'
	printf '  "annotations": [\n'
	printf '    {\n'
	printf '      "annotationType": "OTHER",\n'
	printf '      "annotator": "Tool: scripts/sbom.sh",\n'
	printf '      "annotationDate": "%s",\n' "$created"
	printf '      "comment": "No published asset has a third-party component: build.zig.zon declares no dependency, the binaries are statically linked, and every package it names is a development or benchmark pin that no release artifact contains. Each pin carries NOASSERTION because no manifest in this tree records one; a consumer who needs the license text for a pin reads the project it names. The package and the assets carry the license LICENSE grants."\n'
	printf '    }\n'
	printf '  ]\n'
	printf '}\n'
# The document is written beside its destination and renamed into it, the way
# `make release-assets` stages an asset and `make checksums` stages a sidecar.
# The block above can stop halfway: an asset whose digest cannot be read exits
# from inside it, and a redirect into the final name leaves half a document
# there. Both asset loops above already skip `*.spdx.json` and `*.tmp`, and
# `make checksums` skips `*.tmp` as well, so a leftover is never sidecarred and
# never hashed into the package, but nothing downstream can tell a truncated
# document from a complete one: `check-checksums` reads every `dist/microagent-*`
# back, hashes whatever is there and compares it with the sidecar written from
# the same truncated bytes, so a release would publish an inventory that is not
# JSON. A rename is atomic, so the name holds the previous document or the new
# one and never half of either.
} > "$out.tmp"
mv "$out.tmp" "$out"

echo "wrote $out: $asset_count assets, $pin_count declared pins"
