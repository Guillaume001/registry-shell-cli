#!/usr/bin/env bats
# Tests bout-en-bout de la sous-commande 'pull' (exécution directe du script,
# pas de sourcing, pour exercer trap/mktemp/tar/sha256sum comme en vrai).

load 'test_helper'

setup() {
    cd "$BATS_TEST_TMPDIR"
}

@test "pull --from-dir: produit une archive + .sha256, sans skopeo" {
    build_skopeo_dir "skopeo-src" > /dev/null
    run "$REGISTRY_CLI" pull -i myimage -t 3.20 --from-dir skopeo-src -o out.tar.gz
    [ "$status" -eq 0 ]
    [ -f "out.tar.gz" ]
    [ -f "out.tar.gz.sha256" ]
    [ ! -f "out.tar.gz.asc" ]

    (cd "$BATS_TEST_TMPDIR" && sha256sum -c out.tar.gz.sha256)
}

@test "pull --from-dir: l'archive contient bien v2/<image>/manifests et blobs" {
    build_skopeo_dir "skopeo-src" > /dev/null
    "$REGISTRY_CLI" pull -i myimage -t 3.20 --from-dir skopeo-src -o out.tar.gz --no-expand
    tar -tzf out.tar.gz > listing.txt
    grep -q "^v2/myimage/manifests/3.20$" listing.txt
    grep -q "^v2/myimage/blobs/sha256:" listing.txt
    grep -q "^registrish-archive.json$" listing.txt
}

@test "pull: nom de fichier de sortie auto-généré à partir de l'image/tag/arch" {
    build_skopeo_dir "skopeo-src" > /dev/null
    run "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src
    [ "$status" -eq 0 ]
    [ -f "docker.io-library-alpine-3.20-fromdir.tar.gz" ]
}

@test "pull: normalise le nom d'image court en forme longue par défaut" {
    build_skopeo_dir "skopeo-src" > /dev/null
    run "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src -o out.tar.gz
    [[ "$output" == *"docker.io/library/alpine"* ]]
    tar -tzf out.tar.gz | grep -q "^v2/docker.io/library/alpine/manifests/3.20$"
}

@test "pull --no-expand: conserve le nom d'image tel quel" {
    build_skopeo_dir "skopeo-src" > /dev/null
    run "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src -o out.tar.gz --no-expand
    [ "$status" -eq 0 ]
    tar -tzf out.tar.gz | grep -q "^v2/alpine/manifests/3.20$"
}

@test "pull: -i manquant est une erreur" {
    run "$REGISTRY_CLI" pull -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"-i/--image est obligatoire"* ]]
}

@test "pull: sans -t ni -d ni --from-dir est une erreur" {
    run "$REGISTRY_CLI" pull -i alpine
    [ "$status" -ne 0 ]
    [[ "$output" == *"précisez -t/--tag et/ou -d/--digest"* ]]
}

@test "pull: sans --from-dir et sans skopeo installé échoue proprement" {
    command -v skopeo >/dev/null 2>&1 && skip "skopeo est installé dans cet environnement"
    run "$REGISTRY_CLI" pull -i alpine -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"skopeo"* ]]
}

@test "pull --from-dir: --digest invalide est rejeté avant tout traitement" {
    run "$REGISTRY_CLI" pull -i alpine -d not-a-digest --from-dir skopeo-src
    [ "$status" -ne 0 ]
    [[ "$output" == *"digest invalide"* ]]
}

@test "pull --from-dir: --from-dir introuvable est une erreur explicite" {
    run "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir /no/such/dir
    [ "$status" -ne 0 ]
    [[ "$output" == *"--from-dir introuvable"* ]]
}

@test "pull -k: échoue si gpg-key fournie mais gpg absent (simulation par sourcing)" {
    build_skopeo_dir "skopeo-src" > /dev/null
    load_registry_cli
    command() {
        if [[ "$1" == "-v" && "$2" == "gpg" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    run cmd_pull -i alpine -t 3.20 --from-dir skopeo-src -o out.tar.gz -k somekey
    [ "$status" -ne 0 ]
    [[ "$output" == *"gpg"* ]]
}

# --- pull -c/--config (mode multi-images/tags via skopeo sync) -------------

@test "pull -c: erreur si combiné avec -i" {
    printf 'docker.io: {}\n' > sync.yaml
    run "$REGISTRY_CLI" pull -c sync.yaml -i alpine -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"incompatible avec -i/-t/-d/--from-dir"* ]]
}

@test "pull -c: erreur si le fichier de config est introuvable" {
    run "$REGISTRY_CLI" pull -c absent.yaml
    [ "$status" -ne 0 ]
    [[ "$output" == *"fichier de config introuvable"* ]]
}

@test "pull -c: empaquette tous les tags synchronisés dans une seule archive, nommée d'après le fichier de config" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    build_sync_dir_entry "$sync_out" "quay.io/coreos/etcd" "latest" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\nquay.io:\n  images:\n    coreos/etcd:\n      - latest\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" pull -c sync.yaml

    [ "$status" -eq 0 ]
    [ -f "sync-mirror.tar.gz" ]
    [[ "$output" == *"2 tag(s) inclus dans l'archive"* ]]

    tar -xzf sync-mirror.tar.gz -O registrish-archive.json > archive.json
    grep -q '"tool": "registry-cli.sh pull --config"' archive.json
    grep -q '"image": "docker.io/library/alpine"' archive.json
    grep -q '"image": "quay.io/coreos/etcd"' archive.json

    tar -tzf sync-mirror.tar.gz > listing.txt
    grep -q "^v2/docker.io/library/alpine/manifests/3.20\$" listing.txt
    grep -q "^v2/quay.io/coreos/etcd/manifests/latest\$" listing.txt
}

@test "pull -c -o: le nom d'archive explicite est respecté" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" pull -c sync.yaml -o custom.tar.gz

    [ "$status" -eq 0 ]
    [ -f "custom.tar.gz" ]
    [ ! -f "sync-mirror.tar.gz" ]
}

@test "pull -c: l'archive produite s'upload comme n'importe quelle autre (transfert vers une autre machine)" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" > /dev/null
    build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "latest" > /dev/null
    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n      - "latest"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        "$REGISTRY_CLI" pull -c sync.yaml -o mirror.tar.gz

    run "$REGISTRY_CLI" upload -a mirror.tar.gz -r "${BATS_TEST_TMPDIR}/root"
    [ "$status" -eq 0 ]
    [ -f "${BATS_TEST_TMPDIR}/root/v2/docker.io/library/alpine/manifests/3.20" ]
    [ -f "${BATS_TEST_TMPDIR}/root/v2/docker.io/library/alpine/manifests/latest" ]
}

@test "pull -c: erreur si aucun tag n'est synchronisé (config vide/sans correspondance)" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    mkdir -p "$sync_out"
    printf 'docker.io:\n  images: {}\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    printf 'sync.yaml\t%s\n' "$sync_out" > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" pull -c sync.yaml

    [ "$status" -ne 0 ]
    [[ "$output" == *"aucun tag synchronisé"* ]]
}

@test "pull -c --with-signatures: embarque aussi les artefacts cosign des tags synchronisés" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    local sync_out="${BATS_TEST_TMPDIR}/sync-out"
    local digest_hex
    digest_hex="$(build_sync_dir_entry "$sync_out" "docker.io/library/alpine" "3.20" | awk '{print $3}')"
    build_skopeo_dir "${BATS_TEST_TMPDIR}/sig-src" > /dev/null

    printf 'docker.io:\n  images:\n    library/alpine:\n      - "3.20"\n' > sync.yaml

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    {
        printf 'sync.yaml\t%s\n' "$sync_out"
        printf '.sig\t%s\n' "${BATS_TEST_TMPDIR}/sig-src"
        printf '.att\tFAIL\n'
        printf '.sbom\tFAIL\n'
        printf ':sha256-%s\tFAIL\n' "$digest_hex"
    } > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" pull -c sync.yaml --with-signatures

    [ "$status" -eq 0 ]
    tar -tzf sync-mirror.tar.gz > listing.txt
    grep -q "^v2/docker.io/library/alpine/manifests/sha256-${digest_hex}.sig\$" listing.txt
}
