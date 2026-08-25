#!/usr/bin/env bats
# Tests de la sous-commande 'mirror' : synchronisation (skopeo sync + config
# YAML) de plusieurs images/tags directement dans une registry existante, en
# place -- pensée pour être rejouée périodiquement (cron).

load 'test_helper'

# --- validation des arguments ----------------------------------------------

@test "mirror: erreur si -c/--config manquant" {
    cd "$BATS_TEST_TMPDIR"
    run "$REGISTRY_CLI" mirror -r root
    [ "$status" -ne 0 ]
    [[ "$output" == *"-c/--config est obligatoire"* ]]
}

@test "mirror: erreur si -r/--registry-root manquant" {
    cd "$BATS_TEST_TMPDIR"
    printf 'docker.io: {}\n' > sync.yaml
    run "$REGISTRY_CLI" mirror -c sync.yaml
    [ "$status" -ne 0 ]
    [[ "$output" == *"-r/--registry-root est obligatoire"* ]]
}

@test "mirror: erreur si le fichier de config est introuvable" {
    cd "$BATS_TEST_TMPDIR"
    run "$REGISTRY_CLI" mirror -c absent.yaml -r root
    [ "$status" -ne 0 ]
    [[ "$output" == *"fichier de config introuvable"* ]]
}

# --- fusion de base ----------------------------------------------------

@test "mirror: fusionne un tag synchronisé dans REGISTRY_ROOT/v2 et régénère .htaccess/index.html" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root

    [ "$status" -eq 0 ]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
    [[ "$output" == *"1 tag(s) mirroré(s)"* ]]

    [ -f "root/v2/.htaccess" ]
    [ -f "root/v2/error.json" ]
    [ -f "root/index.html" ]
}

@test "mirror: deux tags de la même image partageant le même digest -> un seul fichier sha256:xxx canonique" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    local digest_hex
    digest_hex="$(build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" | awk '{print $3}')"
    # Même contenu exact pour "latest" (donc même digest de manifest) :
    # on copie le répertoire "3.20" déjà produit sous "latest".
    cp -a "${sync_out}/docker.io/library/alpine:3.20" "${sync_out}/docker.io/library/alpine:latest"

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n      - "latest"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root

    [ "$status" -eq 0 ]
    [[ "$output" == *"2 tag(s) mirroré(s)"* ]]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
    [ -f "root/v2/docker.io/library/alpine/manifests/latest" ]
    [ -f "root/v2/docker.io/library/alpine/manifests/sha256:${digest_hex}" ]
}

@test "mirror: deux images différentes sont toutes les deux fusionnées" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    build_sync_dir_entry "$sync_out" "quay.io/coreos/etcd" "latest" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\nquay.io:\n  images:\n    coreos/etcd:\n      - latest\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root

    [ "$status" -eq 0 ]
    [[ "$output" == *"2 tag(s) mirroré(s)"* ]]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
    [ -f "root/v2/quay.io/coreos/etcd/manifests/latest" ]
}

@test "mirror: fusion additive et idempotente -- relancer deux fois ne casse rien" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root
    [ "$status" -eq 0 ]

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root
    [ "$status" -eq 0 ]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
}

@test "mirror --no-regen-config: ne régénère pas .htaccess/index.html" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root --no-regen-config

    [ "$status" -eq 0 ]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
    [ ! -f "root/v2/.htaccess" ]
    [ ! -f "root/index.html" ]
}

@test "mirror --dry-run: ne touche pas REGISTRY_ROOT" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"--dry-run"* ]]
    [ ! -d "root/v2" ]
}

@test "mirror --keep-going: le flag est accepté et transmis sans casser le flux normal" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root --keep-going

    [ "$status" -eq 0 ]
    [ -f "root/v2/docker.io/library/alpine/manifests/3.20" ]
}

# --- --with-signatures -------------------------------------------------

@test "mirror --with-signatures: récupère les artefacts cosign pour chaque tag synchronisé, une seule fois par digest" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    local digest_hex
    digest_hex="$(build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" | awk '{print $3}')"
    # "latest" pointe sur le même contenu (même digest) : les companions
    # cosign ne doivent être recherchés qu'une seule fois pour ce digest.
    cp -a "${sync_out}/docker.io/library/alpine:3.20" "${sync_out}/docker.io/library/alpine:latest"

    build_skopeo_dir "${BATS_TEST_TMPDIR}/sig-src" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n      - "latest"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    {
        printf 'sync.yaml\t%s\n' "$sync_out"
        printf '.sig\t%s\n' "${BATS_TEST_TMPDIR}/sig-src"
        printf '.att\tFAIL\n'
        printf '.sbom\tFAIL\n'
        printf ':sha256-%s\tFAIL\n' "$digest_hex"
    } > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root --with-signatures

    [ "$status" -eq 0 ]
    [ -f "root/v2/docker.io/library/alpine/manifests/sha256-${digest_hex}.sig" ]
    # Une seule tentative de récupération par digest : le message "trouvé"
    # n'apparaît qu'une fois, pas deux (3.20 et latest partagent le digest).
    local occurrences
    occurrences="$(grep -o "trouvé : sha256-${digest_hex}.sig" <<< "$output" | wc -l | tr -d ' ')"
    [ "$occurrences" -eq 1 ]
}

@test "mirror sans --with-signatures: aucun artefact cosign recherché" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" mirror -c sync.yaml -r root

    [ "$status" -eq 0 ]
    [[ "$output" != *"cosign"* ]]
    [[ "$output" != *".sig"* ]]
}
