#!/usr/bin/env bats
# Tests unitaires des fonctions utilitaires partagées de registry-cli.sh.

load 'test_helper'

setup() {
    load_registry_cli
}

# --- normalize_digest --------------------------------------------------

@test "normalize_digest: accepte un digest déjà préfixé sha256:" {
    local d="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    run normalize_digest "sha256:${d}"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:${d}" ]
}

@test "normalize_digest: ajoute le préfixe sha256: manquant" {
    local d="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    run normalize_digest "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:${d}" ]
}

@test "normalize_digest: rejette un digest trop court" {
    run normalize_digest "sha256:abcd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"digest invalide"* ]]
}

@test "normalize_digest: rejette des caractères non hexadécimaux" {
    run normalize_digest "sha256:zzzz567890123456789012345678901234567890123456789012345678901a"
    [ "$status" -eq 1 ]
}

# --- normalize_image_name ----------------------------------------------

@test "normalize_image_name: image courte -> docker.io/library/<image>" {
    run normalize_image_name "alpine"
    [ "$output" = "docker.io/library/alpine" ]
}

@test "normalize_image_name: namespace/image -> docker.io/namespace/image" {
    run normalize_image_name "dxflrs/garage"
    [ "$output" = "docker.io/dxflrs/garage" ]
}

@test "normalize_image_name: déjà qualifié (docker.io/...) reste inchangé" {
    run normalize_image_name "docker.io/library/alpine"
    [ "$output" = "docker.io/library/alpine" ]
}

@test "normalize_image_name: hôte avec point (quay.io/...) reste inchangé" {
    run normalize_image_name "quay.io/foo/bar"
    [ "$output" = "quay.io/foo/bar" ]
}

@test "normalize_image_name: localhost reste inchangé" {
    run normalize_image_name "localhost/foo"
    [ "$output" = "localhost/foo" ]
}

@test "normalize_image_name: localhost:PORT reste inchangé" {
    run normalize_image_name "localhost:5000/foo"
    [ "$output" = "localhost:5000/foo" ]
}

@test "normalize_image_name: hôte avec port sans nom explicite reste inchangé" {
    run normalize_image_name "myregistry:5000/foo/bar"
    [ "$output" = "myregistry:5000/foo/bar" ]
}

# --- extract_referenced_digests -----------------------------------------

@test "extract_referenced_digests: extrait tous les digests référencés" {
    local f="${BATS_TEST_TMPDIR}/manifest.json"
    cat > "$f" <<'JSON'
{"config":{"digest":"sha256:aaaa000000000000000000000000000000000000000000000000000000000"},
 "layers":[
   {"digest":"sha256:bbbb000000000000000000000000000000000000000000000000000000000"},
   {"digest":"sha256:cccc000000000000000000000000000000000000000000000000000000000"}
 ]}
JSON
    run extract_referenced_digests "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aaaa000000000000000000000000000000000000000000000000000000000"* ]]
    [[ "$output" == *"bbbb000000000000000000000000000000000000000000000000000000000"* ]]
    [[ "$output" == *"cccc000000000000000000000000000000000000000000000000000000000"* ]]
}

@test "extract_referenced_digests: fichier sans digest -> sortie vide" {
    local f="${BATS_TEST_TMPDIR}/empty.json"
    echo '{"foo":"bar"}' > "$f"
    # grep ne trouvant aucune correspondance retourne un statut non nul
    # (comportement normal de grep, propagé par le pipeline) ; seule la
    # sortie (vide) nous intéresse ici.
    run extract_referenced_digests "$f"
    [ -z "$output" ]
}

# --- read_media_type -----------------------------------------------------

@test "read_media_type: lit le mediaType via jq" {
    command -v jq >/dev/null 2>&1 || skip "jq non installé dans cet environnement"
    local f="${BATS_TEST_TMPDIR}/m.json"
    echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}' > "$f"
    run read_media_type "$f"
    [ "$output" = "application/vnd.docker.distribution.manifest.v2+json" ]
}

@test "read_media_type: absent -> 'null'" {
    local f="${BATS_TEST_TMPDIR}/m.json"
    echo '{"foo":"bar"}' > "$f"
    run read_media_type "$f"
    [ "$output" = "null" ]
}

@test "read_media_type: repli grep/sed identique quand jq indisponible" {
    local f="${BATS_TEST_TMPDIR}/m.json"
    echo '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}' > "$f"
    # Simule l'absence de jq en masquant temporairement `command -v jq`.
    command() {
        if [[ "$1" == "-v" && "$2" == "jq" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    run read_media_type "$f"
    [ "$output" = "application/vnd.docker.distribution.manifest.v2+json" ]
}

# --- escape_json_string ---------------------------------------------------

@test "escape_json_string: échappe guillemets et antislashs" {
    run escape_json_string 'foo"bar\baz'
    [ "$output" = 'foo\"bar\\baz' ]
}

@test "escape_json_string: chaîne sans caractère spécial inchangée" {
    run escape_json_string 'library/nginx'
    [ "$output" = 'library/nginx' ]
}

# --- manifest_total_size ---------------------------------------------------

@test "manifest_total_size: manifeste + tous les blobs qu'il référence et qui existent" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    local v2="${BATS_TEST_TMPDIR}/v2"
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "$v2"

    local manifest_file="${v2}/myimage/manifests/3.20"
    local blobs_dir="${v2}/myimage/blobs"

    local expected
    expected="$(file_size_bytes "$manifest_file")"
    local f
    for f in "${blobs_dir}"/sha256:*; do
        expected=$((expected + $(file_size_bytes "$f")))
    done

    run manifest_total_size "$manifest_file" "$blobs_dir"
    [ "$output" = "$expected" ]
    # Doit être nettement plus grand que la seule taille du fichier JSON du
    # manifeste (c'était le bug : "Taille" n'affichait que ça).
    [ "$expected" -gt "$(file_size_bytes "$manifest_file")" ]
}

@test "manifest_total_size: ignore un digest référencé mais absent de blobs_dir" {
    local f="${BATS_TEST_TMPDIR}/manifest.json"
    echo '{"config":{"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000"}}' > "$f"
    local blobs_dir="${BATS_TEST_TMPDIR}/no-such-blobs"
    run manifest_total_size "$f" "$blobs_dir"
    [ "$output" = "$(file_size_bytes "$f")" ]
}
