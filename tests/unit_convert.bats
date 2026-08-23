#!/usr/bin/env bats
# Tests unitaires de la conversion skopeo dir: -> arborescence registry v2/
# (convert_skopeo_dir_to_v2 / _shamove_copy), traduction fidèle de dir2reg.sh.

load 'test_helper'

setup() {
    load_registry_cli
    SKOPEO_DIR="${BATS_TEST_TMPDIR}/skopeo-src"
    V2_ROOT="${BATS_TEST_TMPDIR}/v2"
}

@test "convert_skopeo_dir_to_v2: échoue si manifest.json est absent" {
    mkdir -p "$SKOPEO_DIR"
    run convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "mytag" "$V2_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest.json introuvable"* ]]
}

@test "convert_skopeo_dir_to_v2: place le manifest sous le nom du tag ET sous sha256:xxx" {
    build_skopeo_dir "$SKOPEO_DIR" > /dev/null
    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "3.20" "$V2_ROOT"

    [ -f "${V2_ROOT}/myimage/manifests/3.20" ]
    local manifest_digest
    manifest_digest="$(sha256sum "${SKOPEO_DIR}/manifest.json" | cut -d' ' -f1)"
    [ -f "${V2_ROOT}/myimage/manifests/sha256:${manifest_digest}" ]

    # Les deux fichiers doivent avoir un contenu identique au manifest source.
    diff "${V2_ROOT}/myimage/manifests/3.20" "${SKOPEO_DIR}/manifest.json"
    diff "${V2_ROOT}/myimage/manifests/sha256:${manifest_digest}" "${SKOPEO_DIR}/manifest.json"
}

@test "convert_skopeo_dir_to_v2: déplace config+layer vers blobs/ renommés en sha256:xxx" {
    local digests config_digest layer_digest
    digests="$(build_skopeo_dir "$SKOPEO_DIR")"
    read -r config_digest layer_digest _ <<< "$digests"

    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "3.20" "$V2_ROOT"

    [ -f "${V2_ROOT}/myimage/blobs/sha256:${config_digest}" ]
    [ -f "${V2_ROOT}/myimage/blobs/sha256:${layer_digest}" ]
    diff "${V2_ROOT}/myimage/blobs/sha256:${config_digest}" "${SKOPEO_DIR}/${config_digest}"
}

@test "convert_skopeo_dir_to_v2: ignore le fichier 'version' (non copié)" {
    build_skopeo_dir "$SKOPEO_DIR" > /dev/null
    [ -f "${SKOPEO_DIR}/version" ]
    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "3.20" "$V2_ROOT"

    ! find "${V2_ROOT}" -name 'version' | grep -q .
    ! find "${V2_ROOT}" -type f -exec grep -l '^1\.1$' {} \; 2>/dev/null | grep -q .
}

@test "convert_skopeo_dir_to_v2: sans tag, seul le manifest sha256:xxx est écrit (pas de fichier de tag)" {
    build_skopeo_dir "$SKOPEO_DIR" > /dev/null
    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "" "$V2_ROOT"

    local manifest_digest
    manifest_digest="$(sha256sum "${SKOPEO_DIR}/manifest.json" | cut -d' ' -f1)"
    [ -f "${V2_ROOT}/myimage/manifests/sha256:${manifest_digest}" ]
    # Aucun autre fichier que le sha256:xxx dans manifests/.
    local count
    count="$(find "${V2_ROOT}/myimage/manifests" -type f | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ]
}

@test "convert_skopeo_dir_to_v2: *.manifest.json (multi-arch) va dans manifests/ renommé sha256:xxx, jamais comme fichier de tag" {
    build_skopeo_dir "$SKOPEO_DIR" > /dev/null
    local extra_content='{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","fake":"arm64-variant"}'
    printf '%s' "$extra_content" > "${SKOPEO_DIR}/arm64.manifest.json"
    local extra_digest; extra_digest="$(sha256_of "$extra_content")"

    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "myimage" "3.20" "$V2_ROOT"

    [ -f "${V2_ROOT}/myimage/manifests/sha256:${extra_digest}" ]
    [ ! -f "${V2_ROOT}/myimage/manifests/arm64.manifest.json" ]
    [ ! -f "${V2_ROOT}/myimage/manifests/arm64" ]
}

@test "convert_skopeo_dir_to_v2: supporte un nom d'image à namespace imbriqué (ex: library/nginx)" {
    build_skopeo_dir "$SKOPEO_DIR" > /dev/null
    convert_skopeo_dir_to_v2 "$SKOPEO_DIR" "docker.io/library/nginx" "1.25" "$V2_ROOT"

    [ -f "${V2_ROOT}/docker.io/library/nginx/manifests/1.25" ]
    [ -d "${V2_ROOT}/docker.io/library/nginx/blobs" ]
}

@test "_shamove_copy: copie (ne déplace pas) le fichier source, renommé par son sha256" {
    local src="${BATS_TEST_TMPDIR}/src.bin"
    printf 'hello world' > "$src"
    local dest_dir="${BATS_TEST_TMPDIR}/dest"
    mkdir -p "$dest_dir"

    _shamove_copy "$src" "$dest_dir"

    local expected; expected="$(sha256_of 'hello world')"
    [ -f "${dest_dir}/sha256:${expected}" ]
    [ -f "$src" ]  # source non détruite (contrairement au mv de l'original)
}
