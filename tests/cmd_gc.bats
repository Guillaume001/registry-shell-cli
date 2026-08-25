#!/usr/bin/env bats
# Tests de la sous-commande 'gc' : nettoyage des manifests/blobs orphelins de
# TOUTE la registry (pas juste après une suppression de tag précise, comme
# 'remove --gc').

load 'test_helper'

setup() {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "skopeo-src-alpine" > /dev/null
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o alpine.tar.gz --no-expand >/dev/null
    REGISTRY_ROOT="${BATS_TEST_TMPDIR}/registry"
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
}

# Ajoute un blob orphelin (jamais référencé par aucun manifeste) dans
# REGISTRY_ROOT/v2/alpine/blobs, nommé par son propre digest (convention des
# fichiers de blob).
add_orphan_blob() {
    local content="orphan-blob-content-$$"
    local digest; digest="$(sha256_of "$content")"
    printf '%s' "$content" > "${REGISTRY_ROOT}/v2/alpine/blobs/sha256:${digest}"
    printf '%s' "$digest"
}

# Idem pour un manifeste canonique orphelin (sha256:xxx sous manifests/, sans
# fichier de tag pointant dessus).
add_orphan_manifest() {
    local content="orphan-manifest-content-$$"
    local digest; digest="$(sha256_of "$content")"
    printf '%s' "$content" > "${REGISTRY_ROOT}/v2/alpine/manifests/sha256:${digest}"
    printf '%s' "$digest"
}

@test "gc: erreur si -r/--registry-root manquant" {
    run "$REGISTRY_CLI" gc
    [ "$status" -ne 0 ]
    [[ "$output" == *"-r/--registry-root est obligatoire"* ]]
}

@test "gc: erreur si REGISTRY_ROOT/v2 est introuvable" {
    run "$REGISTRY_CLI" gc -r "${BATS_TEST_TMPDIR}/nope" -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"introuvable"* ]]
}

@test "gc: sans -y et sans tty échoue en demandant confirmation" {
    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"-y/--yes"* ]]
}

@test "gc -y: supprime un blob orphelin sans toucher au tag/blob valides" {
    local orphan_digest; orphan_digest="$(add_orphan_blob)"
    [ -f "${REGISTRY_ROOT}/v2/alpine/blobs/sha256:${orphan_digest}" ]

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/blobs/sha256:${orphan_digest}" ]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
    local n_blobs_after
    n_blobs_after="$(find "${REGISTRY_ROOT}/v2/alpine/blobs" -type f -name 'sha256:*' | wc -l | tr -d ' ')"
    [ "$n_blobs_after" -gt 0 ]
}

@test "gc -y: supprime un manifeste canonique orphelin (sans fichier de tag)" {
    local orphan_digest; orphan_digest="$(add_orphan_manifest)"
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/sha256:${orphan_digest}" ]

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/manifests/sha256:${orphan_digest}" ]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
}

@test "gc --dry-run: n'écrit rien mais affiche ce qui serait fait" {
    local orphan_digest; orphan_digest="$(add_orphan_blob)"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run]"* ]]
    [ -f "${REGISTRY_ROOT}/v2/alpine/blobs/sha256:${orphan_digest}" ]
}

@test "gc: nettoie chaque image indépendamment, sans affecter les autres" {
    build_skopeo_dir "skopeo-src-nginx" > /dev/null
    "$REGISTRY_CLI" pull -i library/nginx -t 1.25 --from-dir skopeo-src-nginx -o nginx.tar.gz --no-expand >/dev/null
    "$REGISTRY_CLI" upload -a nginx.tar.gz -r "$REGISTRY_ROOT" >/dev/null

    local orphan_digest; orphan_digest="$(add_orphan_blob)"
    local n_nginx_blobs_before
    n_nginx_blobs_before="$(find "${REGISTRY_ROOT}/v2/library/nginx/blobs" -type f -name 'sha256:*' | wc -l | tr -d ' ')"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/blobs/sha256:${orphan_digest}" ]
    local n_nginx_blobs_after
    n_nginx_blobs_after="$(find "${REGISTRY_ROOT}/v2/library/nginx/blobs" -type f -name 'sha256:*' | wc -l | tr -d ' ')"
    [ "$n_nginx_blobs_after" -eq "$n_nginx_blobs_before" ]
    [ -f "${REGISTRY_ROOT}/v2/library/nginx/manifests/1.25" ]
}

@test "gc: régénère v2/.htaccess et index.html par défaut" {
    add_orphan_blob > /dev/null
    rm -f "${REGISTRY_ROOT}/v2/.htaccess" "${REGISTRY_ROOT}/index.html"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ -f "${REGISTRY_ROOT}/index.html" ]
}

@test "gc --no-regen-config: ne régénère pas v2/.htaccess/index.html" {
    add_orphan_blob > /dev/null
    rm -f "${REGISTRY_ROOT}/v2/.htaccess" "${REGISTRY_ROOT}/index.html"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y --no-regen-config
    [ "$status" -eq 0 ]
    [ ! -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ ! -f "${REGISTRY_ROOT}/index.html" ]
}

@test "gc: conserve les tags compagnons cosign (sig/att/sbom/referrers) et ce qu'ils référencent" {
    build_skopeo_dir "sig-src" > /dev/null
    local digest_hex
    digest_hex="$(sha256sum "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" | cut -d' ' -f1)"
    load_registry_cli
    add_cosign_artifact_from_dir "sig-src" "alpine" "sha256-${digest_hex}.sig" "${REGISTRY_ROOT}/v2"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/sha256-${digest_hex}.sig" ]
}

@test "gc --purge-empty-images (désactivé par défaut) : laisse en place une image sans aucun tag" {
    rm -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y
    [ "$status" -eq 0 ]
    [ -d "${REGISTRY_ROOT}/v2/alpine" ]
}

@test "gc --purge-empty-images: supprime le répertoire d'une image sans aucun tag" {
    rm -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20"

    run "$REGISTRY_CLI" gc -r "$REGISTRY_ROOT" -y --purge-empty-images
    [ "$status" -eq 0 ]
    [ ! -d "${REGISTRY_ROOT}/v2/alpine" ]
}
