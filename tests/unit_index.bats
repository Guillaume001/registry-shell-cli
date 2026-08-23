#!/usr/bin/env bats
# Tests unitaires de la détection de plateforme et de la génération de
# index.html (get_manifest_platforms, regen_index_html).

load 'test_helper'

setup() {
    load_registry_cli
    ROOT="${BATS_TEST_TMPDIR}/registry"
}

@test "get_manifest_platforms: manifeste simple -> lit architecture/os du blob de config" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    run get_manifest_platforms "${ROOT}/v2/myimage/manifests/3.20" "${ROOT}/v2/myimage/blobs"
    [ "$output" = "amd64/linux" ]
}

@test "get_manifest_platforms: manifest-list -> liste toutes les plateformes" {
    local mlist="${BATS_TEST_TMPDIR}/manifest-list.json"
    cat > "$mlist" <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json",
 "manifests":[
   {"platform":{"architecture":"amd64","os":"linux"}},
   {"platform":{"architecture":"arm64","os":"linux"}}
 ]}
JSON
    run get_manifest_platforms "$mlist" "${BATS_TEST_TMPDIR}/blobs-inexistant"
    [ "$output" = "amd64/linux, arm64/linux" ]
}

@test "get_manifest_platforms: blob de config introuvable -> 'unknown'" {
    local f="${BATS_TEST_TMPDIR}/orphan-manifest.json"
    echo '{"config":{"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000"}}' > "$f"
    run get_manifest_platforms "$f" "${BATS_TEST_TMPDIR}/nonexistent-blobs"
    [ "$output" = "unknown" ]
}

@test "regen_index_html: écrit une page contenant les données JSON attendues" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_index_html "$ROOT"

    [ -f "${ROOT}/index.html" ]
    grep -q '"image":"myimage"' "${ROOT}/index.html"
    grep -q '"tag":"3.20"' "${ROOT}/index.html"
    grep -q '"platforms":"amd64/linux"' "${ROOT}/index.html"
    # Le placeholder de date doit avoir été substitué (pas laissé tel quel).
    ! grep -q '@@GENERATED_AT@@' "${ROOT}/index.html"
}

@test "regen_index_html: registry vide -> tableau JSON vide, page toujours valide" {
    mkdir -p "${ROOT}/v2"
    regen_index_html "$ROOT"
    [ -f "${ROOT}/index.html" ]
    grep -q 'const REGISTRY_DATA =' "${ROOT}/index.html"
    grep -q '\[\];' "${ROOT}/index.html"
}

@test "escape_json_string appliqué: un nom d'image avec guillemet ne casse pas le JSON produit" {
    mkdir -p "${ROOT}/v2/weird\"image/manifests" "${ROOT}/v2/weird\"image/blobs"
    echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}' \
        > "${ROOT}/v2/weird\"image/manifests/latest"

    regen_index_html "$ROOT"

    grep -q '\\"image' "${ROOT}/index.html"
}
