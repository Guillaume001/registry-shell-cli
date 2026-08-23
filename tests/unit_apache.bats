#!/usr/bin/env bats
# Tests unitaires de la génération de configuration Apache (regen_apache2_config),
# traduction fidèle de gen-apache2.sh.

load 'test_helper'

setup() {
    load_registry_cli
    ROOT="${BATS_TEST_TMPDIR}/registry"
    mkdir -p "$ROOT"
}

@test "regen_apache2_config: écrit v2/.htaccess et v2/error.json" {
    regen_apache2_config "$ROOT"
    [ -f "${ROOT}/v2/.htaccess" ]
    [ -f "${ROOT}/v2/error.json" ]
    grep -q "ErrorDocument 404 /v2/error.json" "${ROOT}/v2/.htaccess"
    grep -q "MANIFEST_UNKNOWN" "${ROOT}/v2/error.json"
}

@test "regen_apache2_config: ForceType par mediaType sur les fichiers de manifests/" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_apache2_config "$ROOT"

    local htaccess="${ROOT}/v2/myimage/manifests/.htaccess"
    [ -f "$htaccess" ]
    grep -q "ForceType application/vnd.docker.distribution.manifest.v2+json" "$htaccess"
}

@test "regen_apache2_config: en-tête Docker-Content-Digest uniquement sur le fichier de TAG, pas sur sha256:xxx" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_apache2_config "$ROOT"

    local htaccess="${ROOT}/v2/myimage/manifests/.htaccess"
    grep -q "<Files 3.20>" "$htaccess"
    grep -A1 "<Files 3.20>" "$htaccess" | grep -q "Header add Docker-Content-Digest sha256:"

    # Pas de bloc "Header add Docker-Content-Digest" pour un <Files sha256:...>
    ! grep -B1 "Header add Docker-Content-Digest" "$htaccess" | grep -q '<Files sha256:'
}

@test "regen_apache2_config: chaque blobs/ reçoit un .htaccess anti-mod_deflate" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_apache2_config "$ROOT"

    local htaccess="${ROOT}/v2/myimage/blobs/.htaccess"
    [ -f "$htaccess" ]
    grep -q "SetEnv no-gzip 1" "$htaccess"
    grep -q "Header unset Content-Encoding" "$htaccess"
}

@test "regen_apache2_config: trouve les manifests/ d'images à namespace imbriqué (bug corrigé du glob non récursif)" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "docker.io/library/nginx" "1.25" "${ROOT}/v2"

    regen_apache2_config "$ROOT"

    [ -f "${ROOT}/v2/docker.io/library/nginx/manifests/.htaccess" ]
    [ -f "${ROOT}/v2/docker.io/library/nginx/blobs/.htaccess" ]
}

@test "regen_apache2_config: mediaType absent retombe sur manifest.v1+prettyjws (comme jq -r '// null')" {
    mkdir -p "${ROOT}/v2/myimage/manifests" "${ROOT}/v2/myimage/blobs"
    echo '{"noMediaTypeField":true}' > "${ROOT}/v2/myimage/manifests/latest"

    regen_apache2_config "$ROOT"

    grep -q "ForceType application/vnd.docker.distribution.manifest.v1+prettyjws" \
        "${ROOT}/v2/myimage/manifests/.htaccess"
}
