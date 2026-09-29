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
set -eu

: "${1:?usage: sbom.sh <dist directory>}"
: "${SHA256_CMD:?SHA256_CMD is required}"

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
	case "$name" in
	*.sha256 | *.tmp) continue ;;
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
created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# One line per pin, the manifest that declares it last, deduplicated on the pin
# so a package both manifests name is described once, by the first of them.
pins="$(
	for manifest in $manifests; do
		awk -v manifest="$manifest" '/^[A-Za-z0-9_.-]+==/ { print $1 "|" manifest }' "$manifest"
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
digest() {
	path="$1"
	# because: hash_command is a word list, and "shasum -a 256" is three of them
	# shellcheck disable=SC2086
	set -- $hash_command
	"$@" "$path" | cut -d' ' -f1
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
	printf '      "licenseConcluded": "MIT",\n'
	printf '      "licenseDeclared": "MIT",\n'
	printf '      "copyrightText": "%s",\n' "$copyright"
	printf '      "primaryPackagePurpose": "APPLICATION",\n'
	printf '      "comment": "The published assets. The binaries link no libc and carry no third-party code: build.zig.zon declares no dependency, and the files listed below are the whole of what a release is."\n'
	printf '    }'
	# A here-document rather than a pipe: a pipe would run the loop in a
	# subshell, and the separator each entry after the first needs is state.
	while IFS='|' read -r pin manifest; do
		name="${pin%%==*}"
		pin_version="${pin#*==}"
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
		printf '      "comment": "Pinned in %s, for a linter the gate runs or for the benchmark adapter, and in no published asset."\n' "$manifest"
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
		printf '      "licenseConcluded": "NOASSERTION",\n'
		printf '      "licenseDeclared": "NOASSERTION",\n'
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
	printf '      "comment": "No published asset has a third-party component: build.zig.zon declares no dependency, the binaries are statically linked, and every package it names is a development or benchmark pin that no release artifact contains. The licenses are NOASSERTION because no manifest in this tree records one; a consumer who needs the license text for a package reads the project it names."\n'
	printf '    }\n'
	printf '  ]\n'
	printf '}\n'
} > "$out"

echo "wrote $out: $asset_count assets, $pin_count declared pins"
