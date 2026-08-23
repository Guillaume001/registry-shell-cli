# Helper commun aux suites de tests bats de registry-cli.sh.

REGISTRY_CLI="${BATS_TEST_DIRNAME}/../registry-cli.sh"

# Source le script (les fonctions deviennent disponibles) sans déclencher le
# point d'entrée, grâce au garde `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` du
# script : source != exécution directe.
load_registry_cli() {
    # shellcheck source=/dev/null
    source "$REGISTRY_CLI"
}

# Calcule le digest sha256 (sans préfixe) d'une chaîne, comme sha256sum.
sha256_of() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Construit un répertoire "skopeo dir:" minimal et réaliste pour une image
# mono-architecture : un config blob, un layer blob, un manifest.json qui
# les référence, un fichier version.
#   build_skopeo_dir DEST_DIR
# Affiche sur stdout : "<config_digest> <layer_digest> <manifest_digest>"
build_skopeo_dir() {
    local dest="$1"
    mkdir -p "$dest"

    local config_content='{"architecture":"amd64","os":"linux","config":{}}'
    printf '%s' "$config_content" > "${dest}/config.json.tmp"
    local config_digest; config_digest="$(sha256_of "$config_content")"
    mv "${dest}/config.json.tmp" "${dest}/${config_digest}.tmp"

    local layer_content='fake-layer-tarball-content'
    printf '%s' "$layer_content" > "${dest}/layer.tmp"
    local layer_digest; layer_digest="$(sha256_of "$layer_content")"

    local manifest_content
    manifest_content=$(printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":%d,"digest":"sha256:%s"},"layers":[{"mediaType":"application/vnd.docker.image.rootfs.diff.tar.gzip","size":%d,"digest":"sha256:%s"}]}' \
        "${#config_content}" "$config_digest" "${#layer_content}" "$layer_digest")
    local manifest_digest; manifest_digest="$(sha256_of "$manifest_content")"

    mv "${dest}/${config_digest}.tmp" "${dest}/${config_digest}"
    mv "${dest}/layer.tmp" "${dest}/${layer_digest}"
    printf '%s' "$manifest_content" > "${dest}/manifest.json"
    printf '1.1' > "${dest}/version"

    printf '%s %s %s' "$config_digest" "$layer_digest" "$manifest_digest"
}
