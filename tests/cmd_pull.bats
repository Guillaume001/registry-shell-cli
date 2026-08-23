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
