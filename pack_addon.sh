#!/bin/sh -e
# Builds the CCU addon package.
#   dist/hm-hue.tar.gz         install via CCU "Zusatzsoftware" or one-click update
#   dist/hm-hue.tar.gz.sha256  checksum, checked by the one-click update
#   dist/VERSION               read by the update check
# Optional: ./pack_addon.sh --deb  also builds the debmatic package (needs dpkg-buildpackage)

cd "$(dirname "$0")"
version=$(cat VERSION)
dist="$(pwd)/dist"
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${dist}"
for f in VERSION update_script addon hue; do
	cp -a "$f" "${tmp_dir}/"
done
# Credits and software bill of materials go with the addon; the SBOM is also served by the web UI
cp CREDITS.md "${tmp_dir}/addon/CREDITS.md"
python3 tools/make_sbom.py "${dist}/hm-hue.cdx.json" >/dev/null
cp "${dist}/hm-hue.cdx.json" "${tmp_dir}/addon/www/sbom.cdx.json"
chmod 755 "${tmp_dir}/update_script" "${tmp_dir}/hue" "${tmp_dir}/addon/hue.tcl" "${tmp_dir}/addon/hued.tcl"
chmod 755 "${tmp_dir}"/addon/www/*.cgi
find "${tmp_dir}" \( -name "#*" -o -name ".DS_Store" -o -name "*~" -o -name "*.bak*" \) -delete

# Reproducible archive: fixed owner, sorted entries, no macOS metadata
(cd "${tmp_dir}"; COPYFILE_DISABLE=1 tar --owner=root --group=root --format=ustar -czf "${dist}/hm-hue.tar.gz" $(ls -A | sort) 2>/dev/null \
	|| COPYFILE_DISABLE=1 tar -czf "${dist}/hm-hue.tar.gz" $(ls -A | sort))

(cd "${dist}"; if command -v sha256sum >/dev/null; then sha256sum hm-hue.tar.gz; else shasum -a 256 hm-hue.tar.gz; fi) > "${dist}/hm-hue.tar.gz.sha256"
cp VERSION "${dist}/VERSION"
echo "built ${dist}/hm-hue.tar.gz (version ${version})"

if [ "$1" = "--deb" ]; then
	dch -v "${version}-1" -D stable -b -m "new release, see github for changelog"
	dpkg-buildpackage || true
	cp "../hue_${version}-1_amd64.deb" "${dist}/hue_amd64.deb"
fi
