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

@test "regen_apache2_config: affiche un rappel sur AllowOverride (indispensable pour que .htaccess soit pris en compte)" {
    run regen_apache2_config "$ROOT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "AllowOverride"
    echo "$output" | grep -q "unsupported schema version 2"
}

@test "regen_apache2_config: affiche un rappel sur mod_mime_magic/MIMEMagicFile (aucun .htaccess ne peut le neutraliser)" {
    # Régression : vérifié en conditions réelles (Apache + mod_mime_magic
    # actif) qu'aucune combinaison de directives de .htaccess -- ForceType,
    # Header unset/always unset, RemoveEncoding -- ne retire le
    # Content-Encoding que mod_mime_magic attribue lui-même à un blob sans
    # extension. Seul "MIMEMagicFile none" côté VirtualHost/serveur le fait.
    # Ce rappel doit rester visible pour ne pas laisser croire que
    # regen_apache2_config règle tout depuis les fichiers qu'il écrit.
    run regen_apache2_config "$ROOT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "mod_mime_magic"
    echo "$output" | grep -q "MIMEMagicFile"
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
    grep -q "Header always unset Content-Encoding" "$htaccess"
}

# --- Régression : mod_mime_magic (RHEL/CentOS) renifle nos blobs sans
# extension et leur attribue "Content-Type: application/x-tar" +
# "Content-Encoding: x-gzip" -- un alias non standard que ni Go
# (podman/skopeo/docker) ni leur propre détection de compression ne
# reconnaissent, menant à une lecture erronée du corps de la réponse et donc
# à un digest différent de celui attendu ("Digest did not match"). Constaté
# en conditions réelles avec un vrai Apache/RHEL servant une registry
# produite par ce script.

@test "regen_apache2_config: blobs/.htaccess force un Content-Type opaque (empêche le reniflage mod_mime_magic)" {
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"

    regen_apache2_config "$ROOT"

    local htaccess="${ROOT}/v2/myimage/blobs/.htaccess"
    grep -q "^ForceType application/octet-stream$" "$htaccess"
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

# --- Régression : "unsupported schema version 2" chez podman/docker -------
# Un manifeste OCI schemaVersion:2 peut légitimement omettre "mediaType" (le
# protocole OCI Distribution prévoit que le Content-Type HTTP le porte à sa
# place). Avant ce correctif, l'absence de "mediaType" retombait TOUJOURS
# sur le Content-Type schema1 (v1+prettyjws), ce qui fait mentir Apache sur
# le format réel du manifeste et casse le pull côté client : podman/docker
# refusent alors le contenu avec "unsupported schema version 2".

@test "guess_media_type_for_missing_field: manifeste OCI schemaVersion:2 (config+layers) sans mediaType" {
    local f="${BATS_TEST_TMPDIR}/manifest-no-mediatype.json"
    echo '{"schemaVersion":2,"config":{"digest":"sha256:aaaa","size":10},"layers":[{"digest":"sha256:bbbb","size":20}]}' > "$f"
    run guess_media_type_for_missing_field "$f"
    [ "$output" = "application/vnd.oci.image.manifest.v1+json" ]
}

@test "guess_media_type_for_missing_field: index/manifest-list schemaVersion:2 sans mediaType" {
    local f="${BATS_TEST_TMPDIR}/index-no-mediatype.json"
    echo '{"schemaVersion":2,"manifests":[{"digest":"sha256:cccc","size":10}]}' > "$f"
    run guess_media_type_for_missing_field "$f"
    [ "$output" = "application/vnd.oci.image.index.v1+json" ]
}

@test "guess_media_type_for_missing_field: schemaVersion:1 (schema1 historique) reste v1+prettyjws" {
    local f="${BATS_TEST_TMPDIR}/schema1.json"
    echo '{"schemaVersion":1,"name":"foo"}' > "$f"
    run guess_media_type_for_missing_field "$f"
    [ "$output" = "application/vnd.docker.distribution.manifest.v1+prettyjws" ]
}

@test "guess_media_type_for_missing_field: repli grep/sed identique à jq (jq masqué)" {
    local f="${BATS_TEST_TMPDIR}/manifest-no-mediatype.json"
    echo '{"schemaVersion":2,"config":{"digest":"sha256:aaaa","size":10},"layers":[{"digest":"sha256:bbbb","size":20}]}' > "$f"
    command() {
        if [[ "$1" == "-v" && "$2" == "jq" ]]; then return 1; fi
        builtin command "$@"
    }
    run guess_media_type_for_missing_field "$f"
    [ "$output" = "application/vnd.oci.image.manifest.v1+json" ]
}

@test "regen_apache2_config: manifeste OCI schemaVersion:2 sans mediaType obtient le bon ForceType (pas v1+prettyjws)" {
    mkdir -p "${ROOT}/v2/myimage/manifests" "${ROOT}/v2/myimage/blobs"
    echo '{"schemaVersion":2,"config":{"digest":"sha256:aaaa","size":10},"layers":[{"digest":"sha256:bbbb","size":20}]}' \
        > "${ROOT}/v2/myimage/manifests/3.20"

    regen_apache2_config "$ROOT"

    grep -q "ForceType application/vnd.oci.image.manifest.v1+json" "${ROOT}/v2/myimage/manifests/.htaccess"
    ! grep -q "v1+prettyjws" "${ROOT}/v2/myimage/manifests/.htaccess"
}
