#!/usr/bin/env bats
# Tests unitaires de la détection de plateforme et de la génération de
# index.html (get_manifest_platforms, regen_index_html).

load 'test_helper'

setup() {
    load_registry_cli
    ROOT="${BATS_TEST_TMPDIR}/registry"
}

# --- list_manifest_entries ------------------------------------------------
# Régression : une image récupérée par digest seul ('pull -d ... ' sans
# '-t') n'a qu'un manifests/sha256:xxx canonique, aucun fichier de tag.
# Elle doit rester visible dans 'list'/'index' (avec un "tag" vide), au lieu
# d'être totalement invisible.

@test "list_manifest_entries: image taguée normalement -> une seule entrée, sous son nom de tag" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    run list_manifest_entries "${ROOT}/v2/myimage/manifests"
    [ "$status" -eq 0 ]
    local n
    n="$(echo "$output" | wc -l)"
    [ "$n" -eq 1 ]
    [[ "$output" == "3.20"$'\t'*"/manifests/3.20" ]]
}

@test "list_manifest_entries: image récupérée par digest seul (pas de fichier de tag) -> une entrée marquée NO_TAG_MARKER" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    # tag="" : reproduit 'pull -d sha256:... ' sans '-t' -> pas de fichier de
    # tag écrit, seulement manifests/sha256:xxx (voir convert_skopeo_dir_to_v2).
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "" "${ROOT}/v2"

    run list_manifest_entries "${ROOT}/v2/myimage/manifests"
    [ "$status" -eq 0 ]
    local n
    n="$(echo "$output" | wc -l)"
    [ "$n" -eq 1 ]
    [[ "$output" == "${NO_TAG_MARKER}"$'\t'*"/manifests/sha256:"* ]]
}

@test "list_manifest_entries: n'affiche jamais deux fois la même image (tag + canonique)" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    run list_manifest_entries "${ROOT}/v2/myimage/manifests"
    [ "$status" -eq 0 ]
    local n
    n="$(echo "$output" | wc -l)"
    [ "$n" -eq 1 ]
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

@test "regen_index_html: expose le digest de la config (blob config référencé par le manifeste), en plus du digest du manifeste" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    local digests config_digest
    digests="$(build_skopeo_dir "$skopeo_dir")"
    read -r config_digest _ <<< "$digests"
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_index_html "$ROOT"

    grep -q "\"config_digest\":\"sha256:${config_digest}\"" "${ROOT}/index.html"
}

@test "regen_index_html: expose le media type du manifeste" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_index_html "$ROOT"

    grep -q '"media_type":"application/vnd.docker.distribution.manifest.v2+json"' "${ROOT}/index.html"
}

@test "regen_index_html: manifest-list (pas de config au niveau racine) -> config_digest vide" {
    local manifest_dir="${ROOT}/v2/myimage/manifests"
    mkdir -p "$manifest_dir" "${ROOT}/v2/myimage/blobs"
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"sha256:aaaa000000000000000000000000000000000000000000000000000000000","platform":{"architecture":"amd64","os":"linux"}}]}' \
        > "${manifest_dir}/multi"

    regen_index_html "$ROOT"

    grep -q '"config_digest":""' "${ROOT}/index.html"
}

@test "regen_index_html: registry vide -> tableau JSON vide, page toujours valide" {
    mkdir -p "${ROOT}/v2"
    regen_index_html "$ROOT"
    [ -f "${ROOT}/index.html" ]
    grep -q 'const REGISTRY_DATA =' "${ROOT}/index.html"
    grep -q '\[\];' "${ROOT}/index.html"
}

@test "regen_index_html: contient les points d'ancrage JS du tableau de bord groupé par image" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_index_html "$ROOT"

    # Regression : le tableau de bord regroupe les tags par image (et par
    # digest à l'intérieur d'une image) côté client -- ces points d'ancrage
    # doivent rester présents pour que le JS puisse s'y accrocher.
    grep -q 'id="stats-bar"' "${ROOT}/index.html"
    grep -q 'id="images"' "${ROOT}/index.html"
    grep -q 'id="sort-mode"' "${ROOT}/index.html"
    grep -q 'id="toggle-all"' "${ROOT}/index.html"
    grep -q 'function groupByImage' "${ROOT}/index.html"
}

@test "regen_index_html: le JS préfixe la copie par l'hôte servant la page, et utilise @sha256:... quand il n'y a pas de tag" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_index_html "$ROOT"

    grep -q 'const HOST_PREFIX' "${ROOT}/index.html"
    grep -q 'location.host' "${ROOT}/index.html"
    # Avec tag : HOST_PREFIX + image:tag. Sans tag : HOST_PREFIX + image@digest.
    grep -q '\${HOST_PREFIX}\${g.image}:\${t}' "${ROOT}/index.html"
    grep -q '\${HOST_PREFIX}\${g.image}@\${dg.digest}' "${ROOT}/index.html"
}

@test "regen_index_html: deux tags de contenu identique restent deux entrées JSON distinctes (le regroupement est côté JS)" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"
    # Second tag pointant vers exactement le même contenu (même digest) --
    # simule "latest" pointant sur la même image que "3.20".
    cp "${ROOT}/v2/myimage/manifests/3.20" "${ROOT}/v2/myimage/manifests/latest"

    regen_index_html "$ROOT"

    grep -q '"tag":"3.20"' "${ROOT}/index.html"
    grep -q '"tag":"latest"' "${ROOT}/index.html"
}

@test "escape_json_string appliqué: un nom d'image avec guillemet ne casse pas le JSON produit" {
    mkdir -p "${ROOT}/v2/weird\"image/manifests" "${ROOT}/v2/weird\"image/blobs"
    echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}' \
        > "${ROOT}/v2/weird\"image/manifests/latest"

    regen_index_html "$ROOT"

    grep -q '\\"image' "${ROOT}/index.html"
}
