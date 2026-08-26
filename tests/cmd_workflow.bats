#!/usr/bin/env bats
# Tests bout-en-bout du flux complet : pull --from-dir -> upload -> list ->
# remove (avec GC) -> index. Exécution directe du script (pas de sourcing).

load 'test_helper'

setup() {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "skopeo-src-alpine" > /dev/null
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o alpine.tar.gz --no-expand >/dev/null
    REGISTRY_ROOT="${BATS_TEST_TMPDIR}/registry"
}

@test "upload: échoue si l'archive n'existe pas" {
    run "$REGISTRY_CLI" upload -a nope.tar.gz -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"archive introuvable"* ]]
}

@test "upload: échoue si le checksum ne correspond pas" {
    echo "corruption" >> alpine.tar.gz
    run "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
}

@test "upload: place les fichiers dans REGISTRY_ROOT/v2 et régénère la config" {
    run "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
    [ -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ -f "${REGISTRY_ROOT}/v2/error.json" ]
    [ -f "${REGISTRY_ROOT}/index.html" ]
}

@test "upload --no-regen-config: ne génère pas v2/.htaccess/index.html" {
    run "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" --no-regen-config
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
    [ ! -f "${REGISTRY_ROOT}/v2/.htaccess" ]
    [ ! -f "${REGISTRY_ROOT}/index.html" ]
}

@test "upload --require-signature: échoue sans manifest signé" {
    run "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" --require-signature
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest signé"* ]]
}

@test "upload --require-signature --gpg-keyring: vérifie et fusionne les manifests signés" {
    setup_test_gpg_key
    local key_id="$TEST_GPG_KEY_ID"
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o signed.tar.gz --no-expand -k "$key_id" >/dev/null
    local pubkey="${BATS_TEST_TMPDIR}/pubkey.asc"
    export_test_gpg_pubkey "$key_id" "$pubkey"

    run "$REGISTRY_CLI" upload -a signed.tar.gz -r "$REGISTRY_ROOT" --require-signature --gpg-keyring "$pubkey"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 manifest(s) signé(s) et vérifié(s)"* ]]

    local mf; mf="$(find "${REGISTRY_ROOT}/v2/alpine" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    [ -f "${mf}.asc" ]
}

@test "upload --require-signature --gpg-keyring: échoue avant toute fusion si une signature est invalide" {
    setup_test_gpg_key
    local key_id="$TEST_GPG_KEY_ID"
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o signed.tar.gz --no-expand -k "$key_id" >/dev/null
    local pubkey="${BATS_TEST_TMPDIR}/pubkey.asc"
    export_test_gpg_pubkey "$key_id" "$pubkey"

    # Corrompt le manifest signé DANS l'archive avant upload.
    local workdir="${BATS_TEST_TMPDIR}/tamper"
    mkdir -p "$workdir"
    tar -C "$workdir" -xzf signed.tar.gz
    local mf; mf="$(find "${workdir}/v2" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    echo "tampered" >> "$mf"
    tar -C "$workdir" -czf tampered.tar.gz v2 registrish-archive.json

    run "$REGISTRY_CLI" upload -a tampered.tar.gz -r "$REGISTRY_ROOT" --require-signature --gpg-keyring "$pubkey" --skip-checksum
    [ "$status" -ne 0 ]
    [ ! -d "${REGISTRY_ROOT}/v2" ]
}

@test "upload -a et --from-dir sont mutuellement exclusifs" {
    run "$REGISTRY_CLI" upload -a alpine.tar.gz --from-dir stage -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutuellement exclusifs"* ]]
}

@test "upload: erreur si ni -a ni --from-dir" {
    run "$REGISTRY_CLI" upload -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"-a/--archive ou --from-dir"* ]]
}

@test "upload --from-dir: workflow complet pull --to-dir + rsync + upload --from-dir, signé et vérifié" {
    setup_test_gpg_key
    local key_id="$TEST_GPG_KEY_ID"
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine --no-expand --to-dir stage -k "$key_id" >/dev/null
    local pubkey="${BATS_TEST_TMPDIR}/pubkey.asc"
    export_test_gpg_pubkey "$key_id" "$pubkey"

    # Simule le transfert rsync vers la machine cible par une simple copie.
    local incoming="${BATS_TEST_TMPDIR}/incoming"
    cp -a stage "$incoming"

    run "$REGISTRY_CLI" upload --from-dir "$incoming" -r "$REGISTRY_ROOT" --require-signature --gpg-keyring "$pubkey"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 manifest(s) signé(s) et vérifié(s)"* ]]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]

    local mf; mf="$(find "${REGISTRY_ROOT}/v2/alpine" -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    [ -f "${mf}.asc" ]

    # Le répertoire source n'est jamais modifié par upload.
    [ -d "${incoming}/v2/alpine" ]
}

@test "upload --from-dir: échoue avant toute fusion si un manifest signé est invalide" {
    setup_test_gpg_key
    local key_id="$TEST_GPG_KEY_ID"
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine --no-expand --to-dir stage -k "$key_id" >/dev/null
    local mf; mf="$(find stage/v2 -type f | grep -E '/manifests/sha256:[0-9a-f]{64}$')"
    echo tampered >> "$mf"

    run "$REGISTRY_CLI" upload --from-dir stage -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [ ! -d "${REGISTRY_ROOT}/v2" ]
}

@test "upload --from-dir: erreur si le répertoire ou son v2/ est introuvable" {
    run "$REGISTRY_CLI" upload --from-dir "${BATS_TEST_TMPDIR}/nope" -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"introuvable"* ]]

    mkdir -p empty-dir
    run "$REGISTRY_CLI" upload --from-dir empty-dir -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"v2/"* ]]
}

@test "upload: fusionne deux images distinctes sans rien écraser" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null

    build_skopeo_dir "skopeo-src-nginx" > /dev/null
    "$REGISTRY_CLI" pull -i library/nginx -t 1.25 --from-dir skopeo-src-nginx -o nginx.tar.gz --no-expand >/dev/null
    run "$REGISTRY_CLI" upload -a nginx.tar.gz -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]

    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
    [ -f "${REGISTRY_ROOT}/v2/library/nginx/manifests/1.25" ]
}

@test "list: affiche l'image et le tag après upload" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpine"* ]]
    [[ "$output" == *"3.20"* ]]
}

@test "list --json: produit un tableau JSON valide" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT" --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].image == "alpine" and .[0].tag == "3.20"' >/dev/null
}

@test "list --json: 'size' est la taille TOTALE de l'image (manifeste + blobs), pas juste le manifeste" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    local manifest_bytes
    manifest_bytes="$(stat -c%s "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" 2>/dev/null || stat -f%z "${REGISTRY_ROOT}/v2/alpine/manifests/3.20")"

    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT" --json
    [ "$status" -eq 0 ]
    local reported_size
    reported_size="$(echo "$output" | jq '.[0].size')"
    [ "$reported_size" -gt "$manifest_bytes" ]
    # Le champ s'appelle "size" (le nom "manifest_size" induisait en erreur :
    # ce n'est plus seulement la taille du manifeste).
    echo "$output" | jq -e '.[0] | has("manifest_size") | not' >/dev/null
}

@test "list (texte): l'en-tête de colonne est SIZE, pas MANIFEST_SIZE" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIZE"* ]]
    [[ "$output" != *"MANIFEST_SIZE"* ]]
}

@test "list: registry sans v2/ est une erreur" {
    mkdir -p "$REGISTRY_ROOT"
    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"introuvable"* ]]
}

@test "remove --tag -y: supprime le tag et purge l'image devenue vide (gc+purge par défaut)" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y
    [ "$status" -eq 0 ]
    [ ! -d "${REGISTRY_ROOT}/v2/alpine" ]
}

@test "remove --tag --no-purge-if-empty: laisse le répertoire d'image vide en place" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y --no-purge-if-empty
    [ "$status" -eq 0 ]
    [ -d "${REGISTRY_ROOT}/v2/alpine" ]
    [ ! -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
}

@test "remove --tag --gc: nettoie les blobs devenus orphelins" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    local n_blobs_before
    n_blobs_before="$(find "${REGISTRY_ROOT}/v2/alpine/blobs" -type f -name 'sha256:*' | wc -l | tr -d ' ')"
    [ "$n_blobs_before" -gt 0 ]

    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y --no-purge-if-empty
    [ "$status" -eq 0 ]
    local n_blobs_after
    n_blobs_after="$(find "${REGISTRY_ROOT}/v2/alpine/blobs" -type f -name 'sha256:*' 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n_blobs_after" -eq 0 ]
}

@test "remove --no-gc: conserve les blobs orphelins" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y --no-gc --no-purge-if-empty
    [ "$status" -eq 0 ]
    local n_blobs_after
    n_blobs_after="$(find "${REGISTRY_ROOT}/v2/alpine/blobs" -type f -name 'sha256:*' | wc -l | tr -d ' ')"
    [ "$n_blobs_after" -gt 0 ]
}

@test "remove: --tag et --digest ensemble sont mutuellement exclusifs" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 --digest sha256:00 -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutuellement exclusifs"* ]]
}

@test "remove: --image accepte un nom court et retombe sur le nom long stocké" {
    "$REGISTRY_CLI" pull -i alpine -t 3.20 --from-dir skopeo-src-alpine -o alpine-long.tar.gz >/dev/null
    "$REGISTRY_CLI" upload -a alpine-long.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    [ -d "${REGISTRY_ROOT}/v2/docker.io/library/alpine" ]

    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker.io/library/alpine"* ]]
}

@test "remove: sans -y et sans tty échoue en demandant confirmation" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"confirmation requise"* ]]
    # Rien n'a été supprimé.
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
}

@test "remove --dry-run: ne supprime rien mais affiche ce qui serait fait" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine --tag 3.20 -y --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]]
    [ -f "${REGISTRY_ROOT}/v2/alpine/manifests/3.20" ]
}

@test "remove image entière (sans --tag ni --digest): supprime tout le répertoire" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" >/dev/null
    run "$REGISTRY_CLI" remove -r "$REGISTRY_ROOT" --image alpine -y
    [ "$status" -eq 0 ]
    [ ! -d "${REGISTRY_ROOT}/v2/alpine" ]
}

@test "index: régénère index.html seul, sans toucher au reste" {
    "$REGISTRY_CLI" upload -a alpine.tar.gz -r "$REGISTRY_ROOT" --no-regen-config >/dev/null
    [ ! -f "${REGISTRY_ROOT}/index.html" ]
    run "$REGISTRY_CLI" index -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]
    [ -f "${REGISTRY_ROOT}/index.html" ]
    [ ! -f "${REGISTRY_ROOT}/v2/.htaccess" ]
}

@test "--version affiche la version" {
    run "$REGISTRY_CLI" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry-cli.sh version"* ]]
}

@test "--version reflète le nom sous lequel le script est invoqué (utile une fois installé en paquet sous 'registry-cli')" {
    local renamed="${BATS_TEST_TMPDIR}/registry-cli"
    cp "$REGISTRY_CLI" "$renamed"
    chmod +x "$renamed"
    run "$renamed" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "registry-cli version "* ]]
}

@test "commande inconnue affiche l'usage et échoue" {
    run "$REGISTRY_CLI" bogus-command
    [ "$status" -ne 0 ]
    [[ "$output" == *"Commande inconnue"* ]]
}

@test "completion: produit un script sourçable définissant _registry_cli_complete" {
    run "$REGISTRY_CLI" completion
    [ "$status" -eq 0 ]
    [[ "$output" == *"_registry_cli_complete"* ]]
    [[ "$output" == *"complete -F _registry_cli_complete registry-cli.sh"* ]]
}

# --- Régression : pull par digest seul (sans -t) doit rester visible ------
# Bug signalé : une image récupérée avec 'pull -d sha256:... ' (sans -t,
# cas d'usage documenté et supporté) n'apparaissait ni dans 'list' ni dans
# 'index.html' après 'upload', bien que ses blobs/manifest soient bien
# présents sur disque -- seul le fichier manifests/sha256:xxx canonique
# existe (pas de fichier de tag), et il était exclu à tort de l'énumération.

@test "pull -d sans -t, puis upload : l'image apparaît dans list (texte)" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "skopeo-src-digest" > /dev/null
    local digest_hex
    digest_hex="$(sha256sum skopeo-src-digest/manifest.json | cut -d' ' -f1)"
    "$REGISTRY_CLI" pull -i registry.access.redhat.com/ubi10 -d "sha256:${digest_hex}" \
        --from-dir skopeo-src-digest -o digest-only.tar.gz --no-expand >/dev/null

    "$REGISTRY_CLI" upload -a digest-only.tar.gz -r "$REGISTRY_ROOT" >/dev/null

    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry.access.redhat.com/ubi10"* ]]
    [[ "$output" == *"${digest_hex}"* ]]
    [[ "$output" != *"Aucune image trouvée"* ]]
}

@test "pull -d sans -t, puis upload : l'image apparaît dans list --json avec tag vide" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "skopeo-src-digest" > /dev/null
    local digest_hex
    digest_hex="$(sha256sum skopeo-src-digest/manifest.json | cut -d' ' -f1)"
    "$REGISTRY_CLI" pull -i registry.access.redhat.com/ubi10 -d "sha256:${digest_hex}" \
        --from-dir skopeo-src-digest -o digest-only.tar.gz --no-expand >/dev/null

    "$REGISTRY_CLI" upload -a digest-only.tar.gz -r "$REGISTRY_ROOT" --no-regen-config >/dev/null

    run "$REGISTRY_CLI" list -r "$REGISTRY_ROOT" --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg d "sha256:${digest_hex}" \
        '.[] | select(.image == "registry.access.redhat.com/ubi10") | .tag == "" and .digest == $d' \
        | grep -q true
}

@test "pull -d sans -t, puis upload : l'image apparaît dans index.html" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "skopeo-src-digest" > /dev/null
    "$REGISTRY_CLI" pull -i registry.access.redhat.com/ubi10 -d "sha256:$(sha256sum skopeo-src-digest/manifest.json | cut -d' ' -f1)" \
        --from-dir skopeo-src-digest -o digest-only.tar.gz --no-expand >/dev/null

    "$REGISTRY_CLI" upload -a digest-only.tar.gz -r "$REGISTRY_ROOT" >/dev/null

    grep -q '"image":"registry.access.redhat.com/ubi10","tag":""' "${REGISTRY_ROOT}/index.html"
}
