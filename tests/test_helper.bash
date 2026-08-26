# Helper commun aux suites de tests bats de registry-cli.sh.

REGISTRY_CLI="${BATS_TEST_DIRNAME}/../registry-cli.sh"

# Source le script (les fonctions deviennent disponibles) sans déclencher le
# point d'entrée, grâce au garde `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` du
# script : source != exécution directe.
load_registry_cli() {
    # shellcheck source=/dev/null
    source "$REGISTRY_CLI"
}

# Calcule le digest sha256 (sans préfixe) d'une chaîne, comme sha256sum.
sha256_of() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Construit un répertoire "skopeo dir:" minimal et réaliste pour une image
# mono-architecture : un config blob, un layer blob, un manifest.json qui
# les référence, un fichier version.
#   build_skopeo_dir DEST_DIR
# Affiche sur stdout : "<config_digest> <layer_digest> <manifest_digest>"
build_skopeo_dir() {
    local dest="$1"
    mkdir -p "$dest"

    local config_content='{"architecture":"amd64","os":"linux","config":{}}'
    printf '%s' "$config_content" > "${dest}/config.json.tmp"
    local config_digest; config_digest="$(sha256_of "$config_content")"
    mv "${dest}/config.json.tmp" "${dest}/${config_digest}.tmp"

    local layer_content='fake-layer-tarball-content'
    printf '%s' "$layer_content" > "${dest}/layer.tmp"
    local layer_digest; layer_digest="$(sha256_of "$layer_content")"

    local manifest_content
    manifest_content=$(printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":%d,"digest":"sha256:%s"},"layers":[{"mediaType":"application/vnd.docker.image.rootfs.diff.tar.gzip","size":%d,"digest":"sha256:%s"}]}' \
        "${#config_content}" "$config_digest" "${#layer_content}" "$layer_digest")
    local manifest_digest; manifest_digest="$(sha256_of "$manifest_content")"

    mv "${dest}/${config_digest}.tmp" "${dest}/${config_digest}"
    mv "${dest}/layer.tmp" "${dest}/${layer_digest}"
    printf '%s' "$manifest_content" > "${dest}/manifest.json"
    printf '1.1' > "${dest}/version"

    printf '%s %s %s' "$config_digest" "$layer_digest" "$manifest_digest"
}

# Écrit un exécutable "skopeo" factice dans BIN_DIR (à faire précéder au
# PATH). Simule `skopeo copy [flags] SRC_REF dir:DEST_DIR` en consultant un
# fichier de correspondances TSV (pattern<TAB>action) désigné par la
# variable d'environnement FAKE_SKOPEO_MAP : la première ligne dont le
# pattern est une sous-chaîne de SRC_REF s'applique. "action" est soit un
# répertoire "skopeo dir:" à copier tel quel dans DEST_DIR, soit le mot-clé
# FAIL pour simuler une référence introuvable (skopeo copy non-zéro).
# Permet de tester 'pull --with-signatures' sans réseau ni vrai skopeo.
#
# Simule aussi `skopeo sync --src yaml --dest dir --scoped [--keep-going]
# [--dry-run] CONFIG DEST_DIR` en consultant le MÊME fichier TSV
# (FAKE_SKOPEO_MAP), mais avec CONFIG (le chemin du fichier YAML, pas une
# référence d'image) comme sujet du filtrage par sous-chaîne : "action" est
# alors un répertoire déjà structuré comme une sortie réelle de
# `skopeo sync --dest dir --scoped` (DEST_DIR/<registre>/<image>:<tag>/...),
# copié tel quel dans DEST_DIR. Permet de tester 'mirror' sans réseau ni
# vrai skopeo. Avec --dry-run, rien n'est copié (comme le vrai skopeo sync).
install_fake_skopeo() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "${bin_dir}/skopeo" <<'FAKE_SKOPEO_EOF'
#!/usr/bin/env bash
set -euo pipefail

fake_skopeo_lookup() {
    local subject="$1"
    [[ -n "${FAKE_SKOPEO_MAP:-}" && -f "$FAKE_SKOPEO_MAP" ]] || { echo "fake skopeo: FAKE_SKOPEO_MAP non défini" >&2; exit 2; }
    while IFS=$'\t' read -r pattern action; do
        [[ -z "$pattern" ]] && continue
        if [[ "$subject" == *"$pattern"* ]]; then
            printf '%s' "$action"
            return 0
        fi
    done < "$FAKE_SKOPEO_MAP"
    return 1
}

case "${1:-}" in
    copy)
        shift
        src_ref="" dest_dir=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --override-arch|--override-os) shift 2 ;;
                --all) shift ;;
                dir:*) dest_dir="${1#dir:}"; shift ;;
                *)
                    if [[ -z "$src_ref" ]]; then src_ref="$1"; else dest_dir="${1#dir:}"; fi
                    shift
                    ;;
            esac
        done
        action="$(fake_skopeo_lookup "$src_ref")" || { echo "fake skopeo: aucune correspondance pour $src_ref" >&2; exit 1; }
        if [[ "$action" == "FAIL" ]]; then
            echo "fake skopeo: échec simulé pour $src_ref" >&2
            exit 1
        fi
        mkdir -p "$dest_dir"
        cp -a "${action}/." "$dest_dir/"
        ;;
    sync)
        shift
        dry_run="false" config="" dest_dir=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --src|--dest) shift 2 ;;
                --scoped|--keep-going|-a|--all) shift ;;
                --dry-run) dry_run="true"; shift ;;
                *)
                    if [[ -z "$config" ]]; then config="$1"; else dest_dir="$1"; fi
                    shift
                    ;;
            esac
        done
        action="$(fake_skopeo_lookup "$config")" || { echo "fake skopeo: aucune correspondance pour $config" >&2; exit 1; }
        if [[ "$action" == "FAIL" ]]; then
            echo "fake skopeo: échec simulé pour $config" >&2
            exit 1
        fi
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$dest_dir"
            cp -a "${action}/." "$dest_dir/"
        fi
        ;;
    *)
        echo "fake skopeo: commande non supportée : $*" >&2
        exit 2
        ;;
esac
FAKE_SKOPEO_EOF
    chmod +x "${bin_dir}/skopeo"
}

# Construit, sous DEST_DIR, une arborescence imitant la sortie de
# `skopeo sync --dest dir --scoped` pour UN tag : DEST_DIR/<registre>/<image
# éventuellement imbriquée>:<tag>/{manifest.json,...} (répertoire "skopeo
# dir:" minimal, produit par build_skopeo_dir). Utilisé pour construire le
# répertoire fixture référencé par FAKE_SKOPEO_MAP pour 'mirror'.
#   build_sync_dir_entry DEST_DIR REGISTRY_AND_IMAGE TAG
# Affiche sur stdout : "<config_digest> <layer_digest> <manifest_digest>"
build_sync_dir_entry() {
    local dest_dir="$1" registry_and_image="$2" tag="$3"
    build_skopeo_dir "${dest_dir}/${registry_and_image}:${tag}"
}

# Écrit un exécutable "cosign" factice dans BIN_DIR. Gère juste assez de
# sous-commandes pour tester 'verify'/'sbom' sans le vrai binaire :
#   cosign verify --key ... REF                 -> succès (message stderr)
#   cosign verify-attestation --key ... REF      -> imprime une enveloppe DSSE
#   cosign download attestation ... REF           -> idem, sans vérification
# L'enveloppe imprimée encapsule un prédicat CycloneDX minimal, pour exercer
# le décodage base64+jq réel de cmd_sbom.
install_fake_cosign() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "${bin_dir}/cosign" <<'FAKE_COSIGN_EOF'
#!/usr/bin/env bash
set -euo pipefail
emit_envelope() {
    local predicate='{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}'
    local statement
    statement="$(printf '{"_type":"https://in-toto.io/Statement/v0.1","predicateType":"https://cyclonedx.org/bom","subject":[],"predicate":%s}' "$predicate")"
    local payload
    payload="$(printf '%s' "$statement" | base64 | tr -d '\n')"
    printf '{"payloadType":"application/vnd.in-toto+json","payload":"%s","signatures":[]}\n' "$payload"
}
case "${1:-}" in
    verify)
        echo "fake cosign: signature vérifiée pour $*" >&2
        exit 0
        ;;
    verify-attestation)
        emit_envelope
        exit 0
        ;;
    download)
        if [[ "${2:-}" == "attestation" ]]; then
            emit_envelope
            exit 0
        fi
        echo "fake cosign: sous-commande 'download' non supportée : $*" >&2
        exit 2
        ;;
    *)
        echo "fake cosign: sous-commande non supportée : $*" >&2
        exit 2
        ;;
esac
FAKE_COSIGN_EOF
    chmod +x "${bin_dir}/cosign"
}

# Génère une paire de clés GPG de test (sans passphrase) dans un GNUPGHOME
# temporaire dédié et exporte GNUPGHOME pour le reste du test.
# NE PAS appeler via $(...) : export ne survivrait pas au subshell. Appeler
# directement, puis lire l'identifiant de la clé dans TEST_GPG_KEY_ID :
#   setup_test_gpg_key
#   ... "$TEST_GPG_KEY_ID" ...
setup_test_gpg_key() {
    local gnupghome="${BATS_TEST_TMPDIR}/gnupg-test"
    mkdir -p "$gnupghome"
    chmod 700 "$gnupghome"
    export GNUPGHOME="$gnupghome"
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "registry-cli test <test@example.invalid>" default default never >/dev/null 2>&1
    TEST_GPG_KEY_ID="$(gpg --batch --list-secret-keys --with-colons \
        | awk -F: '/^fpr:/ { print $10; exit }')"
}

# Exporte la clé publique de test (fingerprint donné) dans un fichier, pour
# simuler un trousseau externe (--gpg-keyring) sans réutiliser le GNUPGHOME
# de signature.
#   export_test_gpg_pubkey KEY_ID OUT_FILE
export_test_gpg_pubkey() {
    local key_id="$1" out_file="$2"
    gpg --batch --armor --export "$key_id" > "$out_file"
}
