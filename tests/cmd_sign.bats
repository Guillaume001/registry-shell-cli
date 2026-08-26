#!/usr/bin/env bats
# Tests de la sous-commande 'sign' : signature/vérification GPG par manifest
# canonique (v2/<image>/manifests/sha256:<hex>) d'une registry déjà en place.

load 'test_helper'

setup() {
    cd "$BATS_TEST_TMPDIR"
    REGISTRY_ROOT="${BATS_TEST_TMPDIR}/registry"

    build_skopeo_dir "skopeo-src-alpine" > /dev/null
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o alpine.tar.gz --no-expand >/dev/null
    "$REGISTRY_CLI" pull -i alpine -t latest --from-dir skopeo-src-alpine -o alpine-latest.tar.gz --no-expand >/dev/null
    build_skopeo_dir "skopeo-src-nginx" > /dev/null
    "$REGISTRY_CLI" pull -i nginx -t 1.25 --from-dir skopeo-src-nginx -o nginx.tar.gz --no-expand >/dev/null

    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    "$REGISTRY_CLI" upload -a alpine-latest.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    "$REGISTRY_CLI" upload -a nginx.tar.gz -r "$REGISTRY_ROOT" >/dev/null

    setup_test_gpg_key
    KEY_ID="$TEST_GPG_KEY_ID"
}

canonical_manifests() {
    find "${REGISTRY_ROOT}/v2" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$' | sort
}

@test "sign: erreur si -r/--registry-root manquant" {
    run "$REGISTRY_CLI" sign -k "$KEY_ID"
    [ "$status" -ne 0 ]
    [[ "$output" == *"-r/--registry-root est obligatoire"* ]]
}

@test "sign: erreur si REGISTRY_ROOT/v2 est introuvable" {
    run "$REGISTRY_CLI" sign -r "${BATS_TEST_TMPDIR}/nope" -k "$KEY_ID"
    [ "$status" -ne 0 ]
    [[ "$output" == *"introuvable"* ]]
}

@test "sign: erreur si ni -k ni --check" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"-k/--gpg-key"* ]]
}

@test "sign: erreur si -k et --check en même temps" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"incompatibles"* ]]
}

@test "sign: erreur si -i cible une image inexistante" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y -i does/not-exist
    [ "$status" -ne 0 ]
    [[ "$output" == *"introuvable"* ]]
}

@test "sign -k -y: signe chaque manifest canonique, jamais les blobs/tags/artefacts cosign" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y
    [ "$status" -eq 0 ]

    # alpine:3.20 et alpine:latest partagent le même digest -> un seul manifeste canonique.
    local n_canonical; n_canonical="$(canonical_manifests | wc -l)"
    [ "$n_canonical" -eq 2 ]

    local mf
    while IFS= read -r mf; do
        [ -f "${mf}.asc" ]
        run gpg --batch --verify "${mf}.asc" "$mf"
        [ "$status" -eq 0 ]
    done < <(canonical_manifests)

    # Ni les copies par tag, ni les blobs, ni un éventuel artefact cosign ne sont signés.
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20.asc" ]
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/manifests/latest.asc" ]
    local blob
    for blob in "${REGISTRY_ROOT}"/v2/alpine/blobs/sha256:*; do
        [ ! -f "${blob}.asc" ]
    done
}

@test "sign -k -y: un échec réel de signature GPG (clé invalide) fait échouer la commande, pas un succès silencieux" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "0xDOESNOTEXIST" -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"échec de la signature GPG"* ]]

    local mf
    while IFS= read -r mf; do
        [ ! -f "${mf}.asc" ]
    done < <(canonical_manifests)
}

@test "sign -k -y: idempotent -- relancer sans --force ne re-signe pas" {
    "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y >/dev/null

    local mf; mf="$(canonical_manifests | head -1)"
    local before; before="$(cat "${mf}.asc")"

    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 manifest(s) signé(s)"* ]]

    local after; after="$(cat "${mf}.asc")"
    [ "$before" = "$after" ]
}

@test "sign -k --force -y: re-signe même les manifests déjà signés" {
    "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y >/dev/null

    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" --force -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 manifest(s) signé(s)"* ]]
}

@test "sign --check: registry entièrement signée -> succès" {
    "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y >/dev/null

    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 manifest(s) valide(s)"* ]]
}

@test "sign --check: manifests non signés -> comptés, pas une erreur" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 manifest(s) valide(s), 2 non signé(s)"* ]]
}

@test "sign --check: une signature corrompue échoue net" {
    "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y >/dev/null
    local mf; mf="$(canonical_manifests | head -1)"
    # Altère un octet DANS le bloc armored (un ajout après -----END PGP
    # SIGNATURE----- serait silencieusement ignoré par gpg).
    sed -i '3s/./X/' "${mf}.asc"

    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" --check
    [ "$status" -ne 0 ]
}

@test "sign -k -i: limite la signature à une seule image" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y -i alpine
    [ "$status" -eq 0 ]

    # Le manifeste alpine est signé...
    local alpine_mf; alpine_mf="$(find "${REGISTRY_ROOT}/v2/alpine" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    [ -f "${alpine_mf}.asc" ]

    # ...mais pas celui de nginx.
    local nginx_mf; nginx_mf="$(find "${REGISTRY_ROOT}/v2/nginx" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    [ ! -f "${nginx_mf}.asc" ]
}

@test "sign -k --dry-run: ne modifie rien sur disque" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run]"* ]]

    local mf
    while IFS= read -r mf; do
        [ ! -f "${mf}.asc" ]
    done < <(canonical_manifests)
}

@test "sign -k -y: régénère .htaccess/index.html par défaut, pas avec --no-regen-config" {
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" -y
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ -f "${REGISTRY_ROOT}/index.html" ]

    rm -f "${REGISTRY_ROOT}/v2/.htaccess" "${REGISTRY_ROOT}/index.html"
    run "$REGISTRY_CLI" sign -r "$REGISTRY_ROOT" -k "$KEY_ID" --force -y --no-regen-config
    [ "$status" -eq 0 ]
    [ ! -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ ! -f "${REGISTRY_ROOT}/index.html" ]
}
