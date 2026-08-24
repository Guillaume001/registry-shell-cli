#!/usr/bin/env bash
#
# registry-cli.sh — Outil unique et 100% autonome (offline) pour gérer une
# registry "registrish" (arborescence v2/<image>/{blobs,manifests} servable
# statiquement, cf. https://github.com/jpetazzo/registrish) :
#
#   pull    : télécharge une image (skopeo) et la convertit en archive .tar.gz
#             de l'arborescence v2/, signable avec GPG
#   upload  : vérifie (checksum + signature GPG si présente) et place le
#             contenu d'une archive dans une registry locale (fichiers)
#   list    : inventaire des images/tags présents dans une registry
#   remove  : supprime un tag ou une image entière d'une registry,
#             avec nettoyage optionnel des blobs/manifests orphelins
#
# IMPORTANT — autonomie :
#   Ce script ne clone JAMAIS de dépôt distant et ne dépend d'aucun script
#   externe. La conversion skopeo -> arborescence registry (fonctions
#   convert_skopeo_dir_to_v2 / _shamove_copy) et la génération de la
#   configuration Apache (regen_apache2_config) sont des traductions bash
#   fidèles du dir2reg.sh et gen-apache2.sh originaux du dépôt
#   jpetazzo/registrish, fournis directement par l'utilisateur — ce ne sont
#   plus des suppositions mais bien la même logique (mêmes patterns de
#   classification de fichiers, mêmes en-têtes HTTP, même error.json).
#
# Dépendances : bash, tar, sha256sum, grep, sed, find. skopeo est requis
# uniquement pour 'pull' sans --from-dir. gpg est requis uniquement pour
# signer/vérifier des signatures. jq est utilisé s'il est présent pour lire
# le champ mediaType des manifestes (comme l'original) ; à défaut, un repli
# par grep/sed est utilisé automatiquement.
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REGISTRY_CLI_VERSION="1.0.0"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <commande> [options]

Commandes :
  pull        Télécharge une image et produit une archive (éventuellement signée)
  upload      Place une archive dans une registry (fichiers locaux)
  list        Liste les images et tags disponibles dans une registry
  remove      Supprime un tag ou une image entière d'une registry
  index       (Re)génère la page index.html à la racine de la registry
  verify      Vérifie la signature cosign d'une image (clé publique)
  sbom        Extrait un SBOM CycloneDX attesté (cosign) au format JSON
  completion  Affiche le script d'auto-complétion bash (voir plus bas)

Signatures et SBOM (cosign) :
  'pull --with-signatures' (ou --sig-from-dir/--att-from-dir/--sbom-from-dir
  pour un usage 100% offline) récupère et conserve les artefacts cosign
  associés à une image (signature, attestation, SBOM) au même titre que
  n'importe quel autre tag de la registry. 'verify' et 'sbom' parlent le
  protocole HTTP OCI Distribution et ciblent donc l'URL où la registry est
  SERVIE (Apache2), pas un chemin local -- voir '${SCRIPT_NAME} verify --help'.

Ce script est 100% autonome : aucune connexion réseau n'est requise en
dehors de skopeo lui-même pour 'pull' (utilisez --from-dir pour même s'en
passer). Aucun dépôt n'est cloné.

Utilisez '${SCRIPT_NAME} <commande> --help' pour l'aide détaillée de chaque commande.
Utilisez '${SCRIPT_NAME} --version' pour afficher la version.

Auto-complétion bash (le script est auto-suffisant, rien à télécharger en plus) :
  source <(${SCRIPT_NAME} completion)                                    # session courante
  ${SCRIPT_NAME} completion | sudo tee /etc/bash_completion.d/registry-cli > /dev/null  # permanent

Exemples :
  ${SCRIPT_NAME} pull -i alpine -t 3.20 -o alpine-3.20.tar.gz -k 0xDEADBEEF
  ${SCRIPT_NAME} pull -i alpine -t 3.20 --with-signatures -o alpine-3.20.tar.gz
  ${SCRIPT_NAME} upload -a alpine-3.20.tar.gz -r /srv/registrish
  ${SCRIPT_NAME} list -r /srv/registrish
  ${SCRIPT_NAME} remove -r /srv/registrish --image alpine --tag 3.19 --gc
  ${SCRIPT_NAME} verify -u registry.example.com -i alpine -t 3.20 -k cosign.pub
  ${SCRIPT_NAME} sbom -u registry.example.com -i alpine -t 3.20 -k cosign.pub -o alpine.cdx.json
EOF
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : confirmation avant action destructive
# ---------------------------------------------------------------------------
confirm_or_abort() {
    local yes="$1" prompt="$2"
    [[ "$yes" == "true" ]] && return 0
    if [[ ! -t 0 ]]; then
        echo "Erreur : confirmation requise mais entrée non interactive. Ajoutez -y/--yes." >&2
        exit 1
    fi
    local reply
    read -r -p "${prompt} [y/N] " reply
    case "$reply" in
        y|Y|yes|oui|o|O) return 0 ;;
        *) echo "Annulé." ; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : normalise et valide un digest fourni par l'utilisateur
# (avec ou sans préfixe "sha256:"). Échoue si le format est invalide.
# ---------------------------------------------------------------------------
normalize_digest() {
    local input="$1" full
    case "$input" in
        sha256:*) full="$input" ;;
        *) full="sha256:${input}" ;;
    esac
    if [[ ! "$full" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "Erreur : digest invalide : '${input}' (attendu : sha256 sur 64 caractères hexadécimaux)." >&2
        exit 1
    fi
    echo "$full"
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : étend un nom d'image court/incomplet vers son nom
# long canonique, pour toujours savoir sans ambiguïté d'où vient l'image
# (mêmes règles que Docker/Podman en interne) :
#   alpine              -> docker.io/library/alpine
#   dxflrs/garage        -> docker.io/dxflrs/garage
#   docker.io/library/alpine  -> inchangé (déjà qualifié)
#   quay.io/foo/bar      -> inchangé (premier segment = un hôte, contient un '.')
#   localhost/foo         -> inchangé ('localhost' est toujours traité comme un hôte)
#   localhost:5000/foo    -> inchangé (le premier segment contient ':')
# ---------------------------------------------------------------------------
normalize_image_name() {
    local image="$1" first
    if [[ "$image" != */* ]]; then
        printf 'docker.io/library/%s' "$image"
        return 0
    fi
    first="${image%%/*}"
    if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
        printf '%s' "$image"
    else
        printf 'docker.io/%s' "$image"
    fi
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : extrait tous les "digest": "sha256:xxx" référencés
# dans un fichier JSON (manifeste), sans dépendance à jq. Utilisé par le
# garbage collector de 'remove --gc' (marche sur la registry déjà convertie,
# où tout est nommé sha256:xxx).
# ---------------------------------------------------------------------------
extract_referenced_digests() {
    local json_file="$1"
    grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]+"' "$json_file" 2>/dev/null \
        | grep -oE 'sha256:[0-9a-f]+' | sed 's/^sha256://' | sort -u
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : taille en octets d'un manifeste PLUS tout ce qu'il
# référence et qui existe réellement dans blobs_dir (config, layers -- un
# digest référencé mais absent, ex: un sous-manifeste de manifest-list ou
# un digest hors de cette image, est simplement ignoré). C'est la "taille de
# l'image" au sens utile (ce qui sera effectivement transféré par un
# pull/push), pas la taille du seul fichier JSON du manifeste.
# ---------------------------------------------------------------------------
file_size_bytes() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

manifest_total_size() {
    local manifest_file="$1" blobs_dir="$2"
    local total d blob_file
    total="$(file_size_bytes "$manifest_file")"
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        blob_file="${blobs_dir}/sha256:${d}"
        [[ -f "$blob_file" ]] && total=$((total + $(file_size_bytes "$blob_file")))
    done < <(extract_referenced_digests "$manifest_file")
    printf '%s' "$total"
}

# Lit le champ "mediaType" d'un fichier JSON de manifeste. Utilise jq si
# disponible (comme le script original), sinon un repli par grep/sed.
# Retourne la chaîne "null" si le champ est absent, comme jq -r le ferait.
read_media_type() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.mediaType // "null"' "$f" 2>/dev/null || echo "null"
    else
        local mt
        mt="$(grep -oE '"mediaType"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
        [[ -n "$mt" ]] && echo "$mt" || echo "null"
    fi
}

# ---------------------------------------------------------------------------
# Devine le type MIME d'un manifeste dont le champ "mediaType" est ABSENT,
# à partir de "schemaVersion" et de la forme du document.
#
# Un manifeste JSON schema1 (l'ancien format) n'a jamais de "mediaType" --
# c'était l'hypothèse (correcte à l'époque) derrière le repli historique de
# gen-apache2.sh vers "application/vnd.docker.distribution.manifest.v1+prettyjws"
# quand ce champ manque. Mais un manifeste ou index OCI schemaVersion:2 peut
# LÉGITIMEMENT omettre "mediaType" lui aussi (le protocole OCI Distribution
# prévoit que le Content-Type HTTP le porte à la place lors de la
# négociation de contenu) -- de plus en plus fréquent, Docker Hub servant
# désormais nombre d'images au format OCI. Sur une registry STATIQUE comme
# celle-ci, il n'y a pas de négociation de contenu : c'est justement ce
# ForceType qui joue ce rôle. S'y tromper fait mentir Apache sur le format
# réel du manifeste, et casse le pull côté client : podman/docker refusent
# alors le contenu avec "unsupported schema version 2" (le manifeste est
# bien schema2/OCI, mais annoncé comme schema1 par le Content-Type).
# ---------------------------------------------------------------------------
guess_media_type_for_missing_field() {
    local f="$1" schema_version has_manifests has_config_and_layers
    if command -v jq >/dev/null 2>&1; then
        schema_version="$(jq -r '.schemaVersion // empty' "$f" 2>/dev/null)"
        has_manifests="$(jq -r 'if (.manifests | type) == "array" then "yes" else "no" end' "$f" 2>/dev/null)"
        has_config_and_layers="$(jq -r 'if (.config != null and (.layers | type) == "array") then "yes" else "no" end' "$f" 2>/dev/null)"
    else
        schema_version="$(grep -oE '"schemaVersion"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | head -1 | grep -oE '[0-9]+$')"
        if grep -q '"manifests"[[:space:]]*:[[:space:]]*\[' "$f" 2>/dev/null; then has_manifests="yes"; else has_manifests="no"; fi
        if grep -q '"config"' "$f" 2>/dev/null && grep -q '"layers"[[:space:]]*:[[:space:]]*\[' "$f" 2>/dev/null; then has_config_and_layers="yes"; else has_config_and_layers="no"; fi
    fi

    if [[ "$schema_version" == "2" ]]; then
        if [[ "$has_manifests" == "yes" ]]; then
            printf 'application/vnd.oci.image.index.v1+json'
            return 0
        fi
        if [[ "$has_config_and_layers" == "yes" ]]; then
            printf 'application/vnd.oci.image.manifest.v1+json'
            return 0
        fi
    fi
    # schemaVersion 1, absent, ou forme non reconnue : repli historique.
    printf 'application/vnd.docker.distribution.manifest.v1+prettyjws'
}

# ---------------------------------------------------------------------------
# Utilitaire partagé : reconnaît le nom d'un tag "compagnon" cosign, c'est-à-
# dire un artefact stocké comme un tag ordinaire mais qui n'est pas un tag
# d'image destiné à l'utilisateur :
#   - convention historique "tag-based" de cosign : sha256-<digest>.sig
#     (signature), .att (attestation in-toto, peut embarquer un SBOM), .sbom
#     (SBOM attaché directement, ancienne convention)
#   - repli statique OCI 1.1 "referrers" : sha256-<digest> (sans suffixe),
#     un index listant les manifestes qui référencent cette image (signatures
#     et/ou attestations poussées en mode OCI 1.1 quand la registry ne
#     supporte pas l'API Referrers dynamique -- ce qui est le cas ici,
#     Apache2 ne servant que des fichiers statiques)
# Utilisé pour exclure ces entrées de la liste des tags "normaux" dans
# 'list'/'index', et pour retrouver les artefacts associés à un tag donné.
# ---------------------------------------------------------------------------
is_cosign_companion_tag() {
    [[ "$1" =~ ^sha256-[0-9a-f]{64}(\.sig|\.att|\.sbom)?$ ]]
}

# ---------------------------------------------------------------------------
# Utilitaire partagé par 'list' et 'index' : énumère les entrées à afficher
# pour un répertoire manifests/ donné.
#
# Cas normal : chaque VRAI tag (n'importe quel nom de fichier, hors
# manifeste canonique manifests/sha256:xxx, hors artefact cosign compagnon).
#
# Cas particulier géré ici : une image récupérée par digest SEUL (ex:
# 'pull -d sha256:... ' sans '-t') n'a AUCUN fichier de tag -- seulement son
# manifests/sha256:xxx canonique. Sans traitement particulier, un tel
# manifeste est invisible dans 'list'/'index' (le sha256:xxx canonique est
# volontairement exclu quand un tag existe déjà, pour ne pas lister deux
# fois la même image). On le fait donc apparaître ici avec un nom de tag
# vide dès lors qu'aucun tag existant ne pointe déjà vers ce même digest.
#
# Sortie : une ligne "NOM_TAG<TAB>CHEMIN_FICHIER" par entrée. NOM_TAG vaut
# le marqueur NO_TAG_MARKER (jamais un champ vide) pour une entrée sans tag
# -- "IFS=$'\t' read -r a b" traite la tabulation comme un caractère
# "whitespace IFS" et supprime un premier champ vide avant de découper,
# faisant glisser le CHEMIN_FICHIER dans la variable NOM_TAG côté
# consommateur ; un marqueur non-vide évite ce piège classique de bash.
#
# Un artefact cosign compagnon (tag ou canonique) n'est JAMAIS affiché comme
# entrée à part : on sait déjà, via ses badges sur le vrai tag concerné
# (voir cmd_list/regen_index_html), qu'il existe. Ceci vaut aussi bien pour
# son fichier de tag compagnon (sha256-<digest>.sig/.att/.sbom, ou le tag de
# repli referrers sha256-<digest>) que pour SA PROPRE copie canonique
# manifests/sha256:<digest-de-son-contenu> -- sans quoi cette dernière
# réapparaîtrait comme une fausse image "(sans tag)".
# ---------------------------------------------------------------------------
NO_TAG_MARKER="<sans-tag>"

list_manifest_entries() {
    local manifest_dir="$1"
    local -A tagged_digests=()   # digest déjà affiché comme entrée (tag réel ou image sans tag)
    local -A hidden_digests=()   # digest d'un artefact cosign compagnon -> jamais affiché
    local f base d

    while IFS= read -r f; do
        base="$(basename "$f")"
        d="$(sha256sum "$f" | cut -d' ' -f1)"
        if is_cosign_companion_tag "$base"; then
            hidden_digests["$d"]=1
            continue
        fi
        tagged_digests["$d"]=1
        printf '%s\t%s\n' "$base" "$f"
    done < <(find "$manifest_dir" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null | sort)

    while IFS= read -r f; do
        base="$(basename "$f")"
        d="${base#sha256:}"
        [[ -n "${tagged_digests[$d]:-}" ]] && continue
        [[ -n "${hidden_digests[$d]:-}" ]] && continue
        printf '%s\t%s\n' "$NO_TAG_MARKER" "$f"
    done < <(find "$manifest_dir" -maxdepth 1 -type f -name 'sha256:*' 2>/dev/null | sort)
}

# ===========================================================================
# Conversion "skopeo dir:" -> arborescence registry v2/<image>/{blobs,manifests}
#
# Traduction fidèle en bash du dir2reg.sh original (fourni par l'utilisateur) :
# classification par PATTERN DE NOM DE FICHIER (pas par inspection du
# contenu) :
#   */version         -> ignoré (supprimé côté source dans l'original)
#   *.manifest.json    -> manifest additionnel (multi-arch), renommé sha256:xxx
#   manifest.json      -> manifest racine, copié vers le nom de tag ET
#                          renommé sha256:xxx
#   (tout le reste)     -> blob, renommé sha256:xxx
# ===========================================================================
_shamove_copy() {
    # Équivalent de la fonction shamove() de dir2reg.sh (cp au lieu de mv,
    # pour ne pas détruire le répertoire source skopeo).
    local src="$1" dest_dir="$2"
    local sha
    sha="$(sha256sum "$src" | cut -d' ' -f1)"
    cp "$src" "${dest_dir}/sha256:${sha}"
}

# Args : skopeo_dir  image  tag  dest_v2_root
convert_skopeo_dir_to_v2() {
    local skopeo_dir="$1" image="$2" tag="$3" dest_v2_root="$4"

    [[ -f "${skopeo_dir}/manifest.json" ]] || {
        echo "Erreur : ${skopeo_dir}/manifest.json introuvable (la copie skopeo a-t-elle échoué ?)." >&2
        return 1
    }

    local image_dir="${dest_v2_root}/${image}"
    local manifests_dir="${image_dir}/manifests"
    local blobs_dir="${image_dir}/blobs"
    mkdir -p "$manifests_dir" "$blobs_dir"

    local f base
    for f in "${skopeo_dir}"/*; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            version)
                : # ignoré, comme "rm $FILE" dans l'original
                ;;
            *.manifest.json)
                _shamove_copy "$f" "$manifests_dir"
                ;;
            manifest.json)
                [[ -n "$tag" ]] && cp "$f" "${manifests_dir}/${tag}"
                _shamove_copy "$f" "$manifests_dir"
                ;;
            *)
                _shamove_copy "$f" "$blobs_dir"
                ;;
        esac
    done
    return 0
}

# ===========================================================================
# Artefacts cosign (signature / attestation / SBOM) — voir 'pull --help' et
# la note "Signatures et SBOM (cosign)" de l'aide générale.
#
# Ces artefacts sont de simples tags supplémentaires dans le même dépôt que
# l'image (convention historique sha256-<digest>.sig/.att/.sbom, ou repli
# statique OCI 1.1 via le tag "referrers" sha256-<digest>) : ils transitent
# donc par le même convert_skopeo_dir_to_v2 que n'importe quel tag normal.
# ===========================================================================

# Intègre un artefact cosign déjà téléchargé hors-ligne (répertoire
# "skopeo dir:", ex. produit sur une machine connectée puis transféré) sous
# le nom de tag "compagnon" attendu (ex: sha256-<digest>.sig).
add_cosign_artifact_from_dir() {
    local src_dir="$1" image="$2" companion_tag="$3" v2_root="$4"
    [[ -f "${src_dir}/manifest.json" ]] || {
        echo "Erreur : ${src_dir}/manifest.json introuvable (artefact cosign --*-from-dir invalide : ${src_dir})." >&2
        return 1
    }
    convert_skopeo_dir_to_v2 "$src_dir" "$image" "$companion_tag" "$v2_root"
}

# Tente de télécharger (skopeo) un tag "compagnon" cosign pour l'image
# donnée (ex: sha256-<digest>.sig). Retourne silencieusement 1 si le tag
# n'existe pas côté source : la plupart des images ne sont ni signées ni
# attestées, ce n'est pas une erreur.
try_pull_cosign_tag() {
    local source_ref="$1" image="$2" companion_tag="$3" v2_root="$4" dest_dir="$5"
    mkdir -p "$dest_dir"
    skopeo copy "${source_ref}:${companion_tag}" "dir:${dest_dir}" \
        >"${dest_dir}.log" 2>&1 || return 1
    convert_skopeo_dir_to_v2 "$dest_dir" "$image" "$companion_tag" "$v2_root"
}

# Télécharge (skopeo) le tag de repli statique OCI 1.1 "referrers"
# (sha256-<digest>, sans suffixe) s'il existe, puis récursivement chaque
# manifeste qu'il référence (signatures/attestations poussées en mode
# OCI 1.1 quand la registry source ne supporte pas l'API Referrers
# dynamique). Best-effort : absence silencieuse si le tag n'existe pas.
pull_oci_referrers_fallback() {
    local source_ref="$1" image="$2" digest_hex="$3" v2_root="$4" workdir="$5"
    local referrers_tag="sha256-${digest_hex}"
    local referrers_dir="${workdir}/cosign-referrers-index"
    mkdir -p "$referrers_dir"
    skopeo copy "${source_ref}:${referrers_tag}" "dir:${referrers_dir}" \
        >"${referrers_dir}.log" 2>&1 || return 1

    # Certaines registries (constaté sur registry.access.redhat.com) ont un
    # tag "sha256-<digest>" qui n'a RIEN à voir avec la convention de repli
    # OCI 1.1 : c'est un simple alias qui renvoie le manifeste de l'image
    # elle-même, à l'identique (même digest que digest_hex). Le traiter comme
    # un index de referrers masquerait alors l'image réelle -- son digest
    # serait classé "compagnon cosign" et donc exclu de list/index. Un vrai
    # index de referrers est un document DIFFÉRENT de l'image (liste de
    # manifestes sig/att/sbom qui la référencent), jamais identique à elle.
    local referrers_digest
    referrers_digest="$(sha256sum "${referrers_dir}/manifest.json" | cut -d' ' -f1)"
    if [[ "$referrers_digest" == "$digest_hex" ]]; then
        return 1
    fi

    # Tag "compagnon" (forme nue sha256-<digest>, reconnue par
    # is_cosign_companion_tag) plutôt que tag="" : sans ça, ce manifeste
    # n'existerait que sous son nom canonique manifests/sha256:xxx, exactement
    # comme une image récupérée par digest seul -- et réapparaîtrait donc à
    # tort comme une fausse image "(sans tag)" dans 'list'/'index'.
    convert_skopeo_dir_to_v2 "$referrers_dir" "$image" "$referrers_tag" "$v2_root"

    local d n=0 referrer_dir
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        n=$((n + 1))
        referrer_dir="${workdir}/cosign-referrer-${n}"
        mkdir -p "$referrer_dir"
        if skopeo copy "${source_ref}@sha256:${d}" "dir:${referrer_dir}" \
            >"${referrer_dir}.log" 2>&1; then
            convert_skopeo_dir_to_v2 "$referrer_dir" "$image" "sha256-${d}" "$v2_root"
        fi
    done < <(extract_referenced_digests "${referrers_dir}/manifest.json")
    return 0
}

# ===========================================================================
# Génération de la configuration Apache — traduction fidèle en bash de
# gen-apache2.sh (fourni par l'utilisateur) :
#   - copie error.json dans v2/
#   - v2/.htaccess : "ErrorDocument 404 /v2/error.json"
#   - pour chaque v2/<image>/manifests/ : un .htaccess LOCAL qui
#       * force le Content-Type de chaque fichier via son mediaType JSON
#         (défaut : application/vnd.docker.distribution.manifest.v1+prettyjws
#         si le champ est absent, comme jq -r renvoyant "null")
#       * ajoute l'en-tête Docker-Content-Digest sur les fichiers de TAG
#         (pas sur les fichiers sha256:xxx), indispensable au protocole
#         Docker Registry (cf. section "How it works" du README registrish)
#
#   ÉCART ASSUMÉ par rapport à l'original : chaque répertoire blobs/ reçoit
#   désormais un .htaccess désactivant mod_deflate/mod_gzip. Les layers
#   d'image sont déjà des tarballs gzip ; si la compression HTTP est active
#   côté serveur (souvent le cas par défaut sur Apache), Apache peut
#   altérer les octets transmis pour ces fichiers déjà compressés, ce qui
#   casse la vérification de digest côté client (erreur "Digest did not
#   match" chez podman/skopeo/docker). L'original ne s'en protège pas.
# ===========================================================================
ERROR_JSON_CONTENT='{"errors":[{"code":"MANIFEST_UNKNOWN","message":"that image or tag does not exist on this registry"}]}'
BLOBS_HTACCESS_CONTENT='<IfModule mod_deflate.c>
  SetEnv no-gzip 1
</IfModule>
<IfModule mod_headers.c>
  Header unset Content-Encoding
</IfModule>'

regen_apache2_config() {
    local root="$1"
    mkdir -p "${root}/v2"

    printf '%s' "$ERROR_JSON_CONTENT" > "${root}/v2/error.json"
    echo "ErrorDocument 404 /v2/error.json" > "${root}/v2/.htaccess"

    local manifest_dir f base content_type sha
    while IFS= read -r manifest_dir; do
        {
            for f in "$manifest_dir"/*; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"
                [[ "$base" == ".htaccess" ]] && continue
                content_type="$(read_media_type "$f")"
                [[ "$content_type" == "null" ]] && content_type="$(guess_media_type_for_missing_field "$f")"
                printf '<Files %s>\n  ForceType %s\n</Files>\n' "$base" "$content_type"
            done
            for f in "$manifest_dir"/*; do
                [[ -f "$f" ]] || continue
                base="$(basename "$f")"
                [[ "$base" == ".htaccess" ]] && continue
                [[ "$base" == sha256:* ]] && continue
                sha="$(sha256sum "$f" | cut -d' ' -f1)"
                printf '<Files %s>\n  Header add Docker-Content-Digest sha256:%s\n</Files>\n' "$base" "$sha"
            done
        } > "${manifest_dir}/.htaccess"
    done < <(find "${root}/v2" -type d -name manifests | sort)

    local blobs_dir
    while IFS= read -r blobs_dir; do
        printf '%s\n' "$BLOBS_HTACCESS_CONTENT" > "${blobs_dir}/.htaccess"
    done < <(find "${root}/v2" -type d -name blobs | sort)

    echo "    v2/.htaccess, v2/error.json, un .htaccess par image (manifests/) et"
    echo "    un .htaccess anti-compression par image (blobs/) ont été écrits."
    echo "    Rappel : ces .htaccess ne sont pris en compte que si Apache a"
    echo "    'AllowOverride All' (ou 'FileInfo') sur ce répertoire — ce n'est"
    echo "    PAS le réglage par défaut de l'image httpd:2.4 officielle. Sans"
    echo "    ça, podman/docker pull échoue avec 'unsupported schema version 2'"
    echo "    (voir section 'Servir la registry avec Apache2' du README)."
}

# ===========================================================================
# Détection de(s) architecture(s) d'un manifeste, pour la page index.html.
#   - manifest-list : lit platform.architecture/os de chaque entrée
#   - manifeste simple : lit le blob de config référencé (config.digest),
#     dont les champs top-level "architecture"/"os" donnent la plateforme
# Utilise jq si présent, sinon repli grep/sed (fonctionne pour du JSON
# compact sur une ligne, ce qui est le cas standard pour ces manifestes).
# ===========================================================================
get_config_digest_from_manifest() {
    local f="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.config.digest // empty' "$f" 2>/dev/null
    else
        grep -oE '"config"[[:space:]]*:[[:space:]]*\{[^}]*\}' "$f" 2>/dev/null \
            | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]+"' \
            | head -1 | grep -oE 'sha256:[0-9a-f]+'
    fi
}

get_platform_from_config_blob() {
    local f="$1" arch os
    if command -v jq >/dev/null 2>&1; then
        arch="$(jq -r '.architecture // "unknown"' "$f" 2>/dev/null)"
        os="$(jq -r '.os // "unknown"' "$f" 2>/dev/null)"
    else
        arch="$(grep -oE '"architecture"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
        os="$(grep -oE '"os"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
    fi
    printf '%s/%s' "${arch:-unknown}" "${os:-unknown}"
}

get_manifest_platforms() {
    local manifest_file="$1" blobs_dir="$2"
    if grep -q '"manifests"[[:space:]]*:' "$manifest_file" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1; then
            jq -r '[.manifests[]? | "\(.platform.architecture // "unknown")/\(.platform.os // "unknown")"] | join(", ")' "$manifest_file" 2>/dev/null
        else
            local block a o out=""
            while IFS= read -r block; do
                a="$(printf '%s' "$block" | grep -oE '"architecture"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')"
                o="$(printf '%s' "$block" | grep -oE '"os"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')"
                [[ -n "$out" ]] && out="${out}, "
                out="${out}${a:-unknown}/${o:-unknown}"
            done < <(grep -oE '"platform"[[:space:]]*:[[:space:]]*\{[^}]*\}' "$manifest_file" 2>/dev/null)
            printf '%s' "$out"
        fi
    else
        local cfg_digest
        cfg_digest="$(get_config_digest_from_manifest "$manifest_file")"
        if [[ -n "$cfg_digest" && -f "${blobs_dir}/${cfg_digest}" ]]; then
            get_platform_from_config_blob "${blobs_dir}/${cfg_digest}"
        else
            printf 'unknown'
        fi
    fi
}

escape_json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ===========================================================================
# Génération de la page index.html à la racine de la registry : tableau de
# bord statique, autonome (aucune ressource externe, CSS/JS inline),
# listant images/tags/architectures/digests, avec recherche et tri côté
# client. N'écrase rien d'autre dans REGISTRY_ROOT.
# ===========================================================================
regen_index_html() {
    local root="$1"
    local index_file="${root}/index.html"

    local manifest_dir image_dir image_name blobs_dir blob_count
    local tag_file tag_name digest digest_hex size mtime platforms
    local has_sig has_att has_sbom config_digest media_type
    local entries=()

    while IFS= read -r manifest_dir; do
        image_dir="$(dirname "$manifest_dir")"
        image_name="${image_dir#"${root}"/v2/}"
        blobs_dir="${image_dir}/blobs"
        blob_count=0
        [[ -d "$blobs_dir" ]] && blob_count=$(find "$blobs_dir" -type f 2>/dev/null | wc -l | tr -d ' ')

        while IFS=$'\t' read -r tag_name tag_file; do
            [[ "$tag_name" == "$NO_TAG_MARKER" ]] && tag_name=""
            digest="sha256:$(sha256sum "$tag_file" | cut -d' ' -f1)"
            digest_hex="${digest#sha256:}"
            mtime="$(date -u -r "$tag_file" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
            platforms="$(get_manifest_platforms "$tag_file" "$blobs_dir")"
            # Vide pour un manifest-list/index (pas de config au niveau
            # racine, seulement pour chaque manifeste par plateforme).
            config_digest="$(get_config_digest_from_manifest "$tag_file")"
            media_type="$(read_media_type "$tag_file")"
            [[ "$media_type" == "null" ]] && media_type="$(guess_media_type_for_missing_field "$tag_file")"
            has_sig="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.sig" ]] && has_sig="true"
            has_att="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.att" ]] && has_att="true"
            has_sbom="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.sbom" ]] && has_sbom="true"
            # Taille de l'IMAGE (manifeste + tous les blobs qu'il référence),
            # pas juste celle du petit fichier JSON du manifeste -- plus les
            # artefacts cosign présents (signature/attestation/SBOM et leurs
            # propres blobs, ex: l'enveloppe DSSE), pour un total réaliste.
            size="$(manifest_total_size "$tag_file" "$blobs_dir")"
            [[ "$has_sig" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.sig" "$blobs_dir")))
            [[ "$has_att" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.att" "$blobs_dir")))
            [[ "$has_sbom" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.sbom" "$blobs_dir")))
            entries+=("$(printf '{"image":"%s","tag":"%s","digest":"%s","config_digest":"%s","media_type":"%s","platforms":"%s","blobs":%s,"size":%s,"mtime":"%s","signed":%s,"attested":%s,"sbom":%s}' \
                "$(escape_json_string "$image_name")" "$(escape_json_string "$tag_name")" \
                "$digest" "$(escape_json_string "$config_digest")" "$(escape_json_string "$media_type")" "$(escape_json_string "$platforms")" "$blob_count" "$size" "$mtime" \
                "$has_sig" "$has_att" "$has_sbom")")
        done < <(list_manifest_entries "$manifest_dir")
    done < <(find "${root}/v2" -type d -name manifests 2>/dev/null | sort)

    local json_array
    if [[ "${#entries[@]}" -eq 0 ]]; then
        json_array="[]"
    else
        json_array="[$(IFS=,; echo "${entries[*]}")]"
    fi

    local generated_at
    generated_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    # Écriture en 3 blocs pour ne jamais faire passer le JSON généré (qui
    # peut contenir n'importe quel caractère issu de noms d'image/tag) par
    # un moteur de substitution (sed/awk) : il est injecté tel quel via
    # printf, sans interprétation.
    cat > "$index_file" <<'HTML_PART1_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Registry — Images disponibles</title>
<style>
  :root {
    /* Palette calquée sur le thème sombre du container registry de GitLab. */
    --bg: #18181b; --panel: #1f1f24; --panel-alt: #212127; --row-hover: #26262d;
    --border: #35353d; --border-soft: #2a2a30;
    --text: #f0f0f2; --text-dim: #9a9aa2; --text-faint: #6b6b73;
    --accent: #6e9eff; --accent-dim: rgba(110,158,255,.14);
    --brand: #fc6d26;
    --good: #3ddb8f; --good-dim: rgba(61,219,143,.14);
    --input-bg: #232329;
    --mono: 'SF Mono', 'Cascadia Code', Consolas, monospace;
    --radius: 6px;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text); padding: 1.75rem clamp(.85rem, 3vw, 2.25rem) 2.5rem;
    -webkit-font-smoothing: antialiased;
  }
  .page { max-width: 1080px; margin: 0 auto; }
  header { margin-bottom: 1.1rem; display: flex; align-items: center; gap: .6rem; }
  .brand-mark {
    flex: 0 0 auto; width: 30px; height: 30px; border-radius: 8px;
    background: linear-gradient(155deg, var(--brand), #e0451c);
    display: flex; align-items: center; justify-content: center; font-size: .95rem;
  }
  h1 { font-size: 1.15rem; margin: 0; font-weight: 700; letter-spacing: -.01em; }
  .subtitle { color: var(--text-faint); font-size: .74rem; margin-top: .15rem; }

  .meta-line {
    display: flex; flex-wrap: wrap; gap: .1rem .9rem; align-items: center;
    color: var(--text-dim); font-size: .8rem; margin: 1rem 0 1.1rem; padding-bottom: 1rem;
    border-bottom: 1px solid var(--border-soft);
  }
  .meta-line strong { color: var(--text); font-weight: 600; }
  .meta-line .good { color: var(--good); }

  .controls {
    margin: 0 0 .85rem; display:flex; gap: .5rem; align-items:center; flex-wrap:wrap;
    position: sticky; top: 0; padding: .5rem 0; background: linear-gradient(var(--bg) 82%, transparent); z-index: 5;
  }
  input[type="search"], select {
    background: var(--input-bg); border: 1px solid var(--border); color: var(--text);
    padding: .45rem .7rem; border-radius: 99px; font-size: .82rem; outline: none;
  }
  input[type="search"] { flex: 1 1 240px; min-width: 180px; }
  input[type="search"]:focus, select:focus, button:focus-visible { border-color: var(--accent); }
  select { flex: 0 0 auto; }
  button.btn {
    background: var(--input-bg); border: 1px solid var(--border); color: var(--text-dim);
    padding: .45rem .8rem; border-radius: 99px; font-size: .78rem; cursor: pointer;
  }
  button.btn:hover { color: var(--text); border-color: var(--accent); }
  .stat-inline { color: var(--text-faint); font-size: .76rem; margin-left: auto; white-space: nowrap; }

  .images { display: flex; flex-direction: column; gap: .6rem; }
  .image-card {
    background: var(--panel); border: 1px solid var(--border-soft); border-radius: var(--radius);
    overflow: hidden; min-width: 0;
  }
  .image-card-header {
    display: flex; align-items: center; gap: .55rem; padding: .65rem .9rem; cursor: pointer; user-select: none;
  }
  .image-card-header:hover { background: var(--row-hover); }
  .chevron { color: var(--text-faint); font-size: .65rem; transition: transform .15s ease; flex: 0 0 auto; }
  .image-card.collapsed .chevron { transform: rotate(-90deg); }
  .image-name { font-weight: 600; font-size: .9rem; overflow-wrap: anywhere; font-family: var(--mono); }
  .image-meta { display:flex; gap: .35rem; flex-wrap: wrap; margin-left: auto; padding-left: .85rem; }
  .image-card-body { border-top: 1px solid var(--border-soft); }
  .image-card.collapsed .image-card-body { display: none; }

  /* Une ligne par groupe de tags (tags de contenu identique regroupés),
     avec panneau de détail dépliable -- inspiré des lignes de tag du
     container registry GitLab (nom, taille, digest court ; le détail
     complet -- digest manifeste, media type, digest config -- n'apparaît
     qu'au clic, plutôt que d'encombrer une table à colonnes fixes). */
  .tag-item { border-top: 1px solid var(--border-soft); }
  .tag-item:first-child { border-top: none; }
  .tag-row {
    display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem;
    padding: .6rem .9rem; cursor: pointer; user-select: none;
  }
  .tag-row:hover { background: var(--row-hover); }
  .tag-row-left { display: flex; gap: .5rem; min-width: 0; }
  .tag-row-chevron { color: var(--text-faint); font-size: .62rem; flex: 0 0 auto; margin-top: .3rem; transition: transform .15s ease; }
  .tag-item.expanded .tag-row-chevron { transform: rotate(90deg); }
  .tag-row-main { min-width: 0; }
  .tags-cell { display: flex; flex-wrap: wrap; }
  .tag-row-sub { display: flex; flex-wrap: wrap; gap: .3rem; margin-top: .3rem; }
  .tag-row-right { flex: 0 0 auto; text-align: right; }
  .tag-row-size { color: var(--text-dim); font-size: .78rem; }
  .tag-row-digest { margin-top: .3rem; }

  .tag-details {
    display: none; padding: .15rem .9rem .8rem 2.35rem; border-top: 1px dashed var(--border-soft);
  }
  .tag-item.expanded .tag-details { display: block; }
  .detail-line { display: flex; gap: .6rem; align-items: baseline; padding: .2rem 0; font-size: .74rem; flex-wrap: wrap; }
  .detail-label { color: var(--text-faint); flex: 0 0 auto; min-width: 9.5rem; }
  .detail-value { font-family: var(--mono); color: var(--text-dim); word-break: break-all; flex: 1 1 200px; min-width: 0; }
  .detail-value.plain { font-family: inherit; }

  .tag { display: inline-flex; align-items:center; gap:.25rem; font-family: var(--mono); background: var(--accent-dim); color: var(--accent);
         padding:.1rem .25rem .1rem .45rem; border-radius:6px; font-size:.74rem; margin: .08rem .2rem .08rem 0; white-space: nowrap; }
  .tag-copy { opacity: .55; cursor: pointer; padding: .05rem .25rem; border-radius: 4px; line-height:1; }
  .tag-copy:hover { opacity: 1; background: rgba(110,158,255,.2); }
  .digest { font-family: var(--mono); color: var(--text-dim); font-size:.72rem; cursor: pointer; white-space: nowrap; }
  .digest::after { content: "⧉"; display: inline-block; opacity: 0; margin-left: .35rem; font-size: .82rem; transition: opacity .1s; }
  .digest:hover { color: var(--text); }
  .digest:hover::after { opacity: .8; }
  .digest.copied { color: var(--good); }
  .digest-none { font-family: var(--mono); color: var(--text-faint); font-size:.72rem; }
  /* Dans le panneau de détail, le digest complet doit pouvoir se rompre sur
     plusieurs lignes (contrairement au digest tronqué de l'en-tête de ligne,
     volontairement sur une seule ligne) -- .digest fixe white-space:nowrap,
     à annuler ici après coup pour que word-break:break-all agisse. */
  .detail-value.digest { white-space: normal; }
  .badge { display:inline-block; background: var(--panel-alt); border:1px solid var(--border);
           padding:.05rem .45rem; border-radius:99px; font-size:.68rem; margin:.08rem .2rem .08rem 0; color: var(--text-dim); }
  .badge-cosign { background: var(--good-dim); border-color: rgba(61,219,143,.35); color: var(--good); }
  .pill { display:inline-flex; align-items:center; gap:.25rem; font-size: .7rem; padding: .15rem .5rem; border-radius: 99px;
          background: var(--panel-alt); border: 1px solid var(--border); color: var(--text-dim); white-space:nowrap; }
  .pill-cosign { background: var(--good-dim); border-color: rgba(61,219,143,.35); color: var(--good); }
  .empty { text-align:center; padding: 2.5rem 1rem; color: var(--text-dim); border: 1px dashed var(--border); border-radius: var(--radius); }
  footer { margin-top: 1.5rem; color: var(--text-faint); font-size:.72rem; text-align: center; }
  ::selection { background: rgba(110,158,255,.28); }
  @media (max-width: 560px) {
    body { padding: 1.1rem .8rem 2rem; }
    .image-meta { padding-left: 0; margin-left: 0; width: 100%; }
    .image-card-header { flex-wrap: wrap; }
    .tag-row { flex-wrap: wrap; }
    .tag-row-right { text-align: left; }
    .detail-label { min-width: 100%; }
  }
</style>
</head>
<body>
<div class="page">
<header>
  <span class="brand-mark">📦</span>
  <div>
    <h1>Registry</h1>
    <div class="subtitle">Générée hors-ligne le @@GENERATED_AT@@ par registry-cli.sh — aucune ressource externe chargée par cette page.</div>
  </div>
</header>

<div class="meta-line" id="stats-bar"></div>

<div class="controls">
  <input type="search" id="search" placeholder="Filtrer par image, tag, digest ou architecture…">
  <select id="sort-mode">
    <option value="name-asc">Nom (A→Z)</option>
    <option value="name-desc">Nom (Z→A)</option>
    <option value="tags-desc">Le plus de tags</option>
    <option value="size-desc">Le plus volumineux</option>
    <option value="recent">Récemment modifié</option>
  </select>
  <button type="button" class="btn" id="toggle-all">Tout replier</button>
  <span class="stat-inline" id="count-label"></span>
</div>

<div class="images" id="images"></div>
<div class="empty" id="empty-state" style="display:none;">Aucune image ne correspond à ce filtre.</div>
<footer>registry-cli.sh</footer>
</div>
<script>
const REGISTRY_DATA =
HTML_PART1_EOF

    printf '%s;\n' "$json_array" >> "$index_file"

    cat >> "$index_file" <<'HTML_PART2_EOF'

const collapsed = new Set();
const expandedRows = new Set();

// Préfixe l'hôte:port depuis lequel cette page est effectivement consultée
// (ex: "localhost:8000/"), pour que les références copiées soient directement
// utilisables en l'état (podman/docker pull, etc.). Vide si la page est
// ouverte en local (file://) plutôt que servie par le même Apache2 que la
// registry -- dans ce cas on ne peut pas deviner l'hôte réel de la registry.
const HOST_PREFIX = (location.protocol === "http:" || location.protocol === "https:") && location.host
    ? location.host + "/" : "";

function humanSize(bytes) {
    if (bytes < 1024) return bytes + " o";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " Ko";
    return (bytes / (1024 * 1024)).toFixed(1) + " Mo";
}

function humanDate(iso) {
    if (!iso) return "?";
    try {
        return new Date(iso).toLocaleString();
    } catch (e) {
        return iso;
    }
}

function shortDigest(d) {
    return d.length > 19 ? d.slice(0, 19) + "…" : d;
}

function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
}

function copyToClipboard(text, el, doneText) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) return;
    navigator.clipboard.writeText(text).then(() => {
        const original = el.textContent;
        el.textContent = doneText;
        el.classList.add("copied");
        setTimeout(() => { el.classList.remove("copied"); el.textContent = original; }, 900);
    }).catch(() => {});
}

// Regroupe une liste de lignes (déjà filtrées) par image, puis par digest à
// l'intérieur de chaque image -- deux tags identiques en contenu (ex:
// "latest" et "3.21" pointant vers le même manifeste) se retrouvent ainsi
// affichés ensemble sur une seule ligne, plutôt que dupliqués.
function groupByImage(rows) {
    const byImage = new Map();
    for (const r of rows) {
        if (!byImage.has(r.image)) byImage.set(r.image, []);
        byImage.get(r.image).push(r);
    }
    const groups = [];
    for (const [image, entries] of byImage) {
        const byDigest = new Map();
        for (const r of entries) {
            if (!byDigest.has(r.digest)) byDigest.set(r.digest, []);
            byDigest.get(r.digest).push(r);
        }
        const digestGroups = [...byDigest.values()].map(tags => ({
            tags: tags.map(t => t.tag).sort((a, b) => a.localeCompare(b)),
            digest: tags[0].digest,
            configDigest: tags[0].config_digest,
            mediaType: tags[0].media_type,
            platforms: tags[0].platforms,
            blobs: tags[0].blobs,
            size: tags[0].size,
            mtime: tags.map(t => t.mtime).sort().pop(),
            signed: tags.some(t => t.signed),
            attested: tags.some(t => t.attested),
            sbom: tags.some(t => t.sbom),
        })).sort((a, b) => a.tags.join(",").localeCompare(b.tags.join(",")));

        groups.push({
            image,
            digestGroups,
            tagCount: entries.length,
            totalSize: entries.reduce((sum, t) => sum + t.size, 0),
            lastModified: entries.map(t => t.mtime).sort().pop() || "",
            anySigned: entries.some(t => t.signed || t.attested || t.sbom),
        });
    }
    return groups;
}

function sortGroups(groups, mode) {
    const byName = (a, b) => a.image.localeCompare(b.image);
    switch (mode) {
        case "name-desc": return groups.sort((a, b) => -byName(a, b));
        case "tags-desc": return groups.sort((a, b) => b.tagCount - a.tagCount || byName(a, b));
        case "size-desc": return groups.sort((a, b) => b.totalSize - a.totalSize || byName(a, b));
        case "recent": return groups.sort((a, b) => b.lastModified.localeCompare(a.lastModified) || byName(a, b));
        default: return groups.sort(byName);
    }
}

function renderStats() {
    const nImages = new Set(REGISTRY_DATA.map(r => r.image)).size;
    const nTags = REGISTRY_DATA.length;
    const nSigned = REGISTRY_DATA.filter(r => r.signed || r.attested || r.sbom).length;
    const totalSize = REGISTRY_DATA.reduce((sum, r) => sum + r.size, 0);

    document.getElementById("stats-bar").innerHTML = `
        <span><strong>${nImages}</strong> image${nImages === 1 ? "" : "s"}</span>
        <span><strong>${nTags}</strong> tag${nTags === 1 ? "" : "s"}</span>
        <span>${humanSize(totalSize)}</span>
        <span class="${nSigned ? "good" : ""}">${nSigned ? "🔏 " : ""}${nSigned} avec cosign</span>
    `;
}

function renderGroup(g) {
    const isCollapsed = collapsed.has(g.image);

    const metaPills = [
        `<span class="pill">${g.tagCount} tag${g.tagCount === 1 ? "" : "s"}</span>`,
        g.anySigned ? '<span class="pill pill-cosign">🔏 cosign</span>' : "",
        `<span class="pill">${humanSize(g.totalSize)}</span>`,
    ].join("");

    const rowsHtml = g.digestGroups.map(dg => {
        const rowKey = g.image + "::" + dg.digest;
        const isExpanded = expandedRows.has(rowKey);

        const tagBadges = dg.tags.map(t => {
            const label = t || "(sans tag)";
            // Sans tag, on ne peut pas référencer l'image par nom:tag -- on
            // copie donc une référence par digest ("image@sha256:...", seule
            // forme utilisable par podman/docker pull dans ce cas).
            const copyPayload = t ? `${HOST_PREFIX}${g.image}:${t}` : `${HOST_PREFIX}${g.image}@${dg.digest}`;
            return `<span class="tag">${escapeHtml(label)}<span class="tag-copy" data-copy="${escapeHtml(copyPayload)}" title="Copier « ${escapeHtml(copyPayload)} »">⧉</span></span>`;
        }).join("");

        const platformBadges = dg.platforms.split(",").map(p => p.trim()).filter(Boolean)
            .map(p => `<span class="badge">${escapeHtml(p)}</span>`).join("") || '<span class="badge">unknown</span>';

        const cosignBadges = [
            dg.signed ? '<span class="badge badge-cosign" title="Signature cosign présente (sha256-&lt;digest&gt;.sig)">🔏 signé</span>' : '',
            dg.attested ? '<span class="badge badge-cosign" title="Attestation cosign présente (sha256-&lt;digest&gt;.att)">📎 attesté</span>' : '',
            dg.sbom ? '<span class="badge badge-cosign" title="SBOM présent (sha256-&lt;digest&gt;.sbom)">📄 SBOM</span>' : '',
        ].join("");

        // Panneau de détail, dans l'esprit du container registry GitLab :
        // replié par défaut, il révèle le digest complet du manifeste, son
        // media type, et le digest de la config -- plutôt que d'imposer ces
        // trois colonnes en permanence dans la ligne.
        const configLine = dg.configDigest
            ? `<div class="detail-line"><span class="detail-label">Digest config</span><span class="digest detail-value" title="${dg.configDigest} (cliquer pour copier)" data-digest="${dg.configDigest}">${dg.configDigest}</span></div>`
            : `<div class="detail-line"><span class="detail-label">Digest config</span><span class="detail-value plain">— (manifest-list/index, pas de config à ce niveau)</span></div>`;

        return `
            <div class="tag-item${isExpanded ? " expanded" : ""}" data-row-toggle="${escapeHtml(rowKey)}">
                <div class="tag-row">
                    <div class="tag-row-left">
                        <span class="tag-row-chevron">▸</span>
                        <div class="tag-row-main">
                            <div class="tags-cell">${tagBadges}</div>
                            <div class="tag-row-sub">${platformBadges}${cosignBadges}</div>
                        </div>
                    </div>
                    <div class="tag-row-right">
                        <div class="tag-row-size">${humanSize(dg.size)} · ${humanDate(dg.mtime)}</div>
                        <div class="tag-row-digest digest" title="${dg.digest} (cliquer pour copier)" data-digest="${dg.digest}">${shortDigest(dg.digest)}</div>
                    </div>
                </div>
                <div class="tag-details">
                    <div class="detail-line"><span class="detail-label">Digest manifeste</span><span class="digest detail-value" title="${dg.digest} (cliquer pour copier)" data-digest="${dg.digest}">${dg.digest}</span></div>
                    <div class="detail-line"><span class="detail-label">Media type</span><span class="detail-value plain">${escapeHtml(dg.mediaType || "?")}</span></div>
                    ${configLine}
                    <div class="detail-line"><span class="detail-label">Blobs</span><span class="detail-value plain">${dg.blobs}</span></div>
                </div>
            </div>`;
    }).join("");

    const card = document.createElement("div");
    card.className = "image-card" + (isCollapsed ? " collapsed" : "");
    card.innerHTML = `
        <div class="image-card-header" data-toggle="${escapeHtml(g.image)}">
            <span class="chevron">▾</span>
            <span class="image-name">${escapeHtml(g.image)}</span>
            <span class="image-meta">${metaPills}</span>
        </div>
        <div class="image-card-body">${rowsHtml}</div>
    `;
    return card;
}

function render() {
    const q = document.getElementById("search").value.trim().toLowerCase();
    const filtered = REGISTRY_DATA.filter(r =>
        !q ||
        r.image.toLowerCase().includes(q) ||
        r.tag.toLowerCase().includes(q) ||
        r.digest.toLowerCase().includes(q) ||
        r.platforms.toLowerCase().includes(q)
    );

    const groups = sortGroups(groupByImage(filtered), document.getElementById("sort-mode").value);

    const container = document.getElementById("images");
    container.innerHTML = "";
    for (const g of groups) container.appendChild(renderGroup(g));

    document.getElementById("empty-state").style.display = groups.length ? "none" : "block";
    container.style.display = groups.length ? "flex" : "none";

    document.getElementById("count-label").textContent =
        filtered.length + " / " + REGISTRY_DATA.length + " tag(s) · " + groups.length + " image(s) affichée(s)";
}

document.getElementById("search").addEventListener("input", render);
document.getElementById("sort-mode").addEventListener("change", render);

document.getElementById("toggle-all").addEventListener("click", (e) => {
    const allCollapsed = document.querySelectorAll(".image-card").length ===
        document.querySelectorAll(".image-card.collapsed").length;
    document.querySelectorAll(".image-card").forEach(card => {
        const key = card.querySelector(".image-card-header").dataset.toggle;
        if (allCollapsed) { collapsed.delete(key); card.classList.remove("collapsed"); }
        else { collapsed.add(key); card.classList.add("collapsed"); }
    });
    e.target.textContent = allCollapsed ? "Tout replier" : "Tout déplier";
});

document.getElementById("images").addEventListener("click", (e) => {
    const header = e.target.closest(".image-card-header");
    if (header) {
        const key = header.dataset.toggle;
        const card = header.closest(".image-card");
        if (collapsed.has(key)) { collapsed.delete(key); card.classList.remove("collapsed"); }
        else { collapsed.add(key); card.classList.add("collapsed"); }
        return;
    }
    const digestCell = e.target.closest(".digest");
    if (digestCell) {
        copyToClipboard(digestCell.dataset.digest, digestCell, "copié !");
        return;
    }
    const tagCopy = e.target.closest(".tag-copy");
    if (tagCopy) {
        copyToClipboard(tagCopy.dataset.copy, tagCopy, "✓");
        return;
    }
    const rowToggle = e.target.closest("[data-row-toggle]");
    if (rowToggle) {
        const key = rowToggle.dataset.rowToggle;
        if (expandedRows.has(key)) { expandedRows.delete(key); rowToggle.classList.remove("expanded"); }
        else { expandedRows.add(key); rowToggle.classList.add("expanded"); }
    }
});

renderStats();
render();
</script>
</body>
</html>
HTML_PART2_EOF

    # Substitution sûre (chaîne de date plate, sans caractères spéciaux) :
    # faite en mémoire bash, sans passer par sed/awk.
    local content
    content="$(cat "$index_file")"
    content="${content//@@GENERATED_AT@@/$generated_at}"
    printf '%s' "$content" > "$index_file"

    echo "    index.html généré : ${index_file}"
}

# ===========================================================================
# Commande : pull
# ===========================================================================
usage_pull() {
    cat <<EOF
Usage: ${SCRIPT_NAME} pull -i IMAGE (-t TAG | -d DIGEST) [-o ARCHIVE.tar.gz] [options]
   ou: ${SCRIPT_NAME} pull -i IMAGE [-t TAG] [-d DIGEST] [-o ARCHIVE.tar.gz] --from-dir DIR

Options obligatoires :
  -i, --image IMAGE          Nom de l'image (ex: alpine, library/nginx)
  -t, --tag TAG              Tag à télécharger (ex: latest, 1.2.3)
  -d, --digest DIGEST        Digest exact à télécharger (avec ou sans préfixe
                               "sha256:"), ex: sha256:abcd... ou juste abcd...
                               Au moins un de -t/-d est requis (sauf avec
                               --from-dir). Les deux peuvent être combinés :
                               le digest précise EXACTEMENT quel contenu
                               télécharger, et le tag sert en plus à créer un
                               pointeur de tag local sur ce même contenu.

Options :
  -o, --output ARCHIVE       Chemin de l'archive tar.gz à produire. Si omis, un nom
                               est généré automatiquement : IMAGE-LABEL-ARCH.tar.gz
                               (LABEL = le tag, ou les 12 premiers caractères du
                               digest si pas de tag), ex : alpine-3.20-amd64.tar.gz
                               ou alpine-a1b2c3d4e5f6-amd64.tar.gz
  -k, --gpg-key KEY_ID       Clé GPG pour signer l'archive (défaut : pas de signature)
      --from-dir DIR         Utilise un répertoire déjà produit par
                               'skopeo copy ... dir:DIR' au lieu d'appeler skopeo
                               (permet un usage 100% offline : téléchargez avec
                               skopeo sur une machine connectée, transférez le
                               répertoire, puis packagez ici sans réseau)
      --source docker://...  Préfixe de source skopeo (défaut : docker://)
      --arch ARCH             Architecture à télécharger (ex: amd64, arm64, arm,
                               386, ppc64le, s390x). Défaut : amd64 (une seule
                               plateforme, téléchargement plus rapide et léger).
                               Utilisez --arch all pour récupérer TOUTES les
                               plateformes disponibles (manifest-list multi-arch,
                               comportement équivalent à l'ancien --all).
      --os OS                 Système d'exploitation à télécharger avec --arch
                               (défaut : linux). Ignoré avec --arch all.
      --no-expand              Ne pas étendre -i/--image vers son nom long canonique
                               (par défaut, "alpine" devient "docker.io/library/alpine",
                               "dxflrs/garage" devient "docker.io/dxflrs/garage", etc.
                               Un nom déjà qualifié — contenant un '.', un ':' avant le
                               premier '/', ou "localhost" — n'est jamais modifié).
                               Uniquement appliqué quand --source vaut "docker://".
      --keep-workdir          Ne pas supprimer le répertoire de travail temporaire

Signatures et SBOM (cosign) — voir aussi '${SCRIPT_NAME} --help' :
      --with-signatures        Recherche et embarque (via skopeo, en plus de
                                 l'image) les artefacts cosign associés :
                                 signature (sha256-<digest>.sig), attestation
                                 (.att, peut contenir un SBOM CycloneDX),
                                 SBOM legacy (.sbom), et le repli statique OCI
                                 1.1 "referrers" (sha256-<digest> + chaque
                                 manifeste qu'il référence). Chaque artefact
                                 absent est ignoré silencieusement (toutes les
                                 images ne sont pas signées). Nécessite skopeo
                                 (incompatible avec --from-dir seul, sauf à
                                 combiner avec les options --*-from-dir
                                 ci-dessous pour rester 100% offline).
      --sig-from-dir DIR        Équivalent 100% offline pour la signature
                                 seule : DIR est un répertoire "skopeo dir:"
                                 déjà produit pour le tag sha256-<digest>.sig
                                 correspondant à cette image (le digest de
                                 l'image venant d'être téléchargée/convertie).
      --att-from-dir DIR        Idem pour l'attestation (.att).
      --sbom-from-dir DIR       Idem pour le SBOM legacy (.sbom).

Exemples :
  ${SCRIPT_NAME} pull -i alpine -t 3.20                        # -> docker.io/library/alpine, archive docker.io-library-alpine-3.20-amd64.tar.gz
  ${SCRIPT_NAME} pull -i dxflrs/garage -t v1.0.1                # -> docker.io/dxflrs/garage
  ${SCRIPT_NAME} pull -i quay.io/foo/bar -t latest               # déjà qualifié, inchangé
  ${SCRIPT_NAME} pull -i alpine -d sha256:abcd...               # -> alpine-abcdxxxxxxxx-amd64.tar.gz
  ${SCRIPT_NAME} pull -i alpine -t 3.20 -d sha256:abcd...        # tag + digest exact combinés
  ${SCRIPT_NAME} pull -i alpine -t 3.20 --arch all               # -> alpine-3.20-all.tar.gz
  ${SCRIPT_NAME} pull -i alpine -t 3.20 -o custom.tar.gz --from-dir /tmp/skopeo-alpine
  ${SCRIPT_NAME} pull -i alpine -t 3.20 --with-signatures        # embarque signature/attestation/SBOM si présentes
EOF
}

cmd_pull() {
    local image="" tag="" digest="" output="" gpg_key="" from_dir=""
    local source_prefix="docker://" arch="amd64" os="linux" keep_workdir="false" no_expand="false"
    local with_signatures="false" sig_from_dir="" att_from_dir="" sbom_from_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--image) image="$2"; shift 2 ;;
            -t|--tag) tag="$2"; shift 2 ;;
            -d|--digest) digest="$2"; shift 2 ;;
            -o|--output) output="$2"; shift 2 ;;
            -k|--gpg-key) gpg_key="$2"; shift 2 ;;
            --from-dir) from_dir="$2"; shift 2 ;;
            --source) source_prefix="$2"; shift 2 ;;
            --arch) arch="$2"; shift 2 ;;
            --os) os="$2"; shift 2 ;;
            --no-expand) no_expand="true"; shift ;;
            --keep-workdir) keep_workdir="true"; shift ;;
            --with-signatures) with_signatures="true"; shift ;;
            --sig-from-dir) sig_from_dir="$2"; shift 2 ;;
            --att-from-dir) att_from_dir="$2"; shift 2 ;;
            --sbom-from-dir) sbom_from_dir="$2"; shift 2 ;;
            -h|--help) usage_pull; exit 0 ;;
            *) echo "Option inconnue pour 'pull' : $1" >&2; exit 1 ;;
        esac
    done

    [[ -z "$image" ]] && { echo "Erreur : -i/--image est obligatoire." >&2; usage_pull; exit 1; }

    if [[ "$no_expand" == "false" && "$source_prefix" == "docker://" ]]; then
        local expanded_image
        expanded_image="$(normalize_image_name "$image")"
        if [[ "$expanded_image" != "$image" ]]; then
            echo "==> Image étendue au format long : ${image} -> ${expanded_image}"
            image="$expanded_image"
        fi
    fi

    local digest_full=""
    if [[ -n "$digest" ]]; then
        digest_full="$(normalize_digest "$digest")"
    fi

    if [[ -z "$from_dir" && -z "$tag" && -z "$digest_full" ]]; then
        echo "Erreur : précisez -t/--tag et/ou -d/--digest." >&2
        usage_pull
        exit 1
    fi

    if [[ -z "$output" ]]; then
        local sanitized_image name_label arch_for_filename
        sanitized_image="$(printf '%s' "$image" | tr '/: ' '---')"
        if [[ -n "$tag" ]]; then
            name_label="$(printf '%s' "$tag" | tr '/: ' '---')"
        elif [[ -n "$digest_full" ]]; then
            name_label="${digest_full#sha256:}"
            name_label="${name_label:0:12}"
        else
            name_label="unknown"
        fi
        if [[ -n "$from_dir" ]]; then
            arch_for_filename="fromdir"
        elif [[ "$arch" == "all" ]]; then
            arch_for_filename="all"
        else
            arch_for_filename="$arch"
        fi
        output="${sanitized_image}-${name_label}-${arch_for_filename}.tar.gz"
        echo "==> Nom de fichier généré automatiquement : ${output}"
    fi

    for bin in tar sha256sum; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Erreur : '$bin' est requis mais introuvable." >&2; exit 1; }
    done
    if [[ -n "$gpg_key" ]]; then
        command -v gpg >/dev/null 2>&1 || { echo "Erreur : 'gpg' est requis pour signer mais introuvable." >&2; exit 1; }
    fi

    local workdir
    workdir="$(mktemp -d "/tmp/registry-cli-pull.XXXXXX")"
    if [[ "$keep_workdir" == "true" ]]; then
        trap 'echo "Répertoire de travail conservé : '"$workdir"'"' EXIT
    else
        trap 'rm -rf "'"$workdir"'"' EXIT
    fi

    local skopeo_dest
    if [[ -n "$from_dir" ]]; then
        [[ -d "$from_dir" ]] || { echo "Erreur : --from-dir introuvable : $from_dir" >&2; exit 1; }
        [[ -f "${from_dir}/manifest.json" ]] || { echo "Erreur : ${from_dir}/manifest.json introuvable (pas une sortie skopeo dir: valide ?)." >&2; exit 1; }
        skopeo_dest="$from_dir"
        echo "==> Utilisation du répertoire skopeo existant : ${from_dir}"
    else
        command -v skopeo >/dev/null 2>&1 || { echo "Erreur : 'skopeo' est requis (ou utilisez --from-dir)." >&2; exit 1; }
        skopeo_dest="${workdir}/src"
        mkdir -p "$skopeo_dest"

        local skopeo_ref
        if [[ -n "$digest_full" ]]; then
            skopeo_ref="${source_prefix}${image}@${digest_full}"
        else
            skopeo_ref="${source_prefix}${image}:${tag}"
        fi

        if [[ "$arch" == "all" ]]; then
            echo "==> Téléchargement de ${skopeo_ref} (toutes les plateformes) avec skopeo..."
            skopeo copy --all "$skopeo_ref" "dir:${skopeo_dest}"
        else
            echo "==> Téléchargement de ${skopeo_ref} (${os}/${arch}) avec skopeo..."
            skopeo copy --override-arch "$arch" --override-os "$os" \
                "$skopeo_ref" "dir:${skopeo_dest}"
        fi
    fi

    echo "==> Conversion en arborescence de registry statique..."
    local v2_root="${workdir}/v2"
    mkdir -p "$v2_root"
    convert_skopeo_dir_to_v2 "$skopeo_dest" "$image" "$tag" "$v2_root" || exit 1

    # --- Artefacts cosign (signature/attestation/SBOM), si demandés ---
    local image_digest_hex=""
    local -a bundled_cosign_artifacts=()
    if [[ "$with_signatures" == "true" || -n "$sig_from_dir" || -n "$att_from_dir" || -n "$sbom_from_dir" ]]; then
        image_digest_hex="$(sha256sum "${skopeo_dest}/manifest.json" | cut -d' ' -f1)"

        if [[ -n "$sig_from_dir" ]]; then
            add_cosign_artifact_from_dir "$sig_from_dir" "$image" "sha256-${image_digest_hex}.sig" "$v2_root" || exit 1
            bundled_cosign_artifacts+=("sha256-${image_digest_hex}.sig (--sig-from-dir)")
        fi
        if [[ -n "$att_from_dir" ]]; then
            add_cosign_artifact_from_dir "$att_from_dir" "$image" "sha256-${image_digest_hex}.att" "$v2_root" || exit 1
            bundled_cosign_artifacts+=("sha256-${image_digest_hex}.att (--att-from-dir)")
        fi
        if [[ -n "$sbom_from_dir" ]]; then
            add_cosign_artifact_from_dir "$sbom_from_dir" "$image" "sha256-${image_digest_hex}.sbom" "$v2_root" || exit 1
            bundled_cosign_artifacts+=("sha256-${image_digest_hex}.sbom (--sbom-from-dir)")
        fi

        if [[ "$with_signatures" == "true" ]]; then
            command -v skopeo >/dev/null 2>&1 || { echo "Erreur : --with-signatures nécessite 'skopeo'." >&2; exit 1; }
            echo "==> Recherche des artefacts cosign associés (signature/attestation/SBOM/referrers)..."

            local companion companion_dir suffix
            for suffix in sig att sbom; do
                companion="sha256-${image_digest_hex}.${suffix}"
                # Ne re-tente pas un artefact déjà fourni via --*-from-dir.
                case "$suffix" in
                    sig) [[ -n "$sig_from_dir" ]] && continue ;;
                    att) [[ -n "$att_from_dir" ]] && continue ;;
                    sbom) [[ -n "$sbom_from_dir" ]] && continue ;;
                esac
                companion_dir="${workdir}/cosign-${suffix}"
                if try_pull_cosign_tag "${source_prefix}${image}" "$image" "$companion" "$v2_root" "$companion_dir"; then
                    echo "    trouvé : ${companion}"
                    bundled_cosign_artifacts+=("$companion")
                else
                    echo "    absent : ${companion}"
                fi
            done

            echo "    recherche du repli statique OCI 1.1 'referrers' (sha256-${image_digest_hex})..."
            if pull_oci_referrers_fallback "${source_prefix}${image}" "$image" "$image_digest_hex" "$v2_root" "$workdir"; then
                echo "    trouvé : index de referrers et ses entrées référencées"
                bundled_cosign_artifacts+=("sha256-${image_digest_hex} (index referrers OCI 1.1)")
            else
                echo "    absent : index de referrers"
            fi
        fi

        if [[ "${#bundled_cosign_artifacts[@]}" -gt 0 ]]; then
            echo "==> Artefacts cosign embarqués :"
            local a
            for a in "${bundled_cosign_artifacts[@]}"; do
                echo "    - ${a}"
            done
        else
            echo "==> Aucun artefact cosign trouvé pour cette image."
        fi
    fi

    local created_at arch_label
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$from_dir" ]]; then
        arch_label="unknown (--from-dir)"
    else
        arch_label="$arch"
    fi
    cat > "${workdir}/registrish-archive.json" <<EOF
{
  "image": "${image}",
  "tag": "${tag}",
  "digest": "${digest_full}",
  "arch": "${arch_label}",
  "created_at": "${created_at}",
  "tool": "registry-cli.sh pull",
  "source": "${source_prefix}${image}"
}
EOF

    mkdir -p "$(dirname "$output")" 2>/dev/null || true
    echo "==> Création de l'archive ${output}..."
    tar -C "$workdir" -czf "$output" v2 registrish-archive.json

    echo "==> Calcul du SHA256..."
    sha256sum "$output" > "${output}.sha256"
    echo "    $(cat "${output}.sha256")"

    if [[ -n "$gpg_key" ]]; then
        echo "==> Signature GPG avec la clé ${gpg_key}..."
        gpg --batch --yes --local-user "$gpg_key" \
            --armor --detach-sign --output "${output}.asc" "$output"
        echo "    Signature écrite dans ${output}.asc"
    else
        echo "==> Aucune clé GPG fournie : archive non signée."
    fi

    echo "==> Terminé."
    echo "    Archive : ${output}"
    echo "    SHA256  : ${output}.sha256"
    if [[ -n "$gpg_key" ]]; then
        echo "    Signature : ${output}.asc"
    fi
}

# ===========================================================================
# Commande : upload
# ===========================================================================
usage_upload() {
    cat <<EOF
Usage: ${SCRIPT_NAME} upload -a ARCHIVE -r REGISTRY_ROOT [options]

Options obligatoires :
  -a, --archive ARCHIVE      Archive .tar.gz produite par 'pull'
  -r, --registry-root DIR    Racine filesystem de la registry

Options :
      --regen-config          Régénère v2/.htaccess (Apache2) après l'ajout des fichiers
                               (défaut : activé — utilisez --no-regen-config pour désactiver)
      --no-regen-config       Désactive la régénération de v2/.htaccess
      --require-signature     Échoue si l'archive n'a pas de signature .asc
      --skip-checksum         Ne vérifie pas le fichier .sha256 associé
      --gpg-keyring FICHIER   Fichier de clés publiques à importer dans un trousseau
                               temporaire pour la vérification de signature

L'archive est vérifiée (checksum + signature GPG si présente), extraite, puis
ses fichiers (v2/blobs/..., v2/manifests/...) sont fusionnés avec ceux déjà
présents dans REGISTRY_ROOT/v2, sans rien supprimer d'existant.

Exemple :
  ${SCRIPT_NAME} upload -a alpine-3.20.tar.gz -r /srv/registrish
EOF
}

cmd_upload() {
    local archive="" root="" regen_config="true"
    local require_signature="false" skip_checksum="false" gpg_keyring=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--archive) archive="$2"; shift 2 ;;
            -r|--registry-root) root="$2"; shift 2 ;;
            --regen-config) regen_config="true"; shift ;;
            --no-regen-config) regen_config="false"; shift ;;
            --require-signature) require_signature="true"; shift ;;
            --skip-checksum) skip_checksum="true"; shift ;;
            --gpg-keyring) gpg_keyring="$2"; shift 2 ;;
            -h|--help) usage_upload; exit 0 ;;
            *) echo "Option inconnue pour 'upload' : $1" >&2; exit 1 ;;
        esac
    done

    [[ -n "$archive" ]] || { echo "Erreur : -a/--archive est obligatoire." >&2; exit 1; }
    [[ -f "$archive" ]] || { echo "Erreur : archive introuvable : $archive" >&2; exit 1; }
    [[ -n "$root" ]] || { echo "Erreur : -r/--registry-root est obligatoire." >&2; exit 1; }

    for bin in tar sha256sum; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Erreur : '$bin' est requis mais introuvable." >&2; exit 1; }
    done

    # --- 1. Vérification du checksum ---
    if [[ "$skip_checksum" == "false" && -f "${archive}.sha256" ]]; then
        echo "==> Vérification du SHA256 de l'archive..."
        local archive_dir; archive_dir="$(dirname "$archive")"
        (cd "$archive_dir" && sha256sum -c "$(basename "${archive}.sha256")") \
            || { echo "Erreur : le SHA256 ne correspond pas. Abandon." >&2; exit 1; }
        echo "    OK."
    fi

    # --- 2. Vérification de la signature GPG (si présente) ---
    local sig_file="${archive}.asc"
    if [[ -f "$sig_file" ]]; then
        command -v gpg >/dev/null 2>&1 || { echo "Erreur : signature présente mais 'gpg' introuvable." >&2; exit 1; }
        echo "==> Vérification de la signature GPG (${sig_file})..."

        local gnupghome_tmp=""
        if [[ -n "$gpg_keyring" ]]; then
            gnupghome_tmp="$(mktemp -d "/tmp/registry-cli-gnupg.XXXXXX")"
            chmod 700 "$gnupghome_tmp"
            export GNUPGHOME="$gnupghome_tmp"
            gpg --batch --quiet --import "$gpg_keyring"
            trap '[[ -n "'"$gnupghome_tmp"'" ]] && rm -rf "'"$gnupghome_tmp"'"' RETURN
        fi

        local gpg_log; gpg_log="$(mktemp "/tmp/registry-cli-gpg-verify.XXXXXX")"
        if gpg --batch --verify "$sig_file" "$archive" 2>&1 | tee "$gpg_log"; then
            grep -q "Good signature" "$gpg_log" || { echo "Erreur : signature non confirmée valide." >&2; rm -f "$gpg_log"; exit 1; }
            echo "    Signature valide."
        else
            echo "Erreur : signature GPG invalide. Abandon." >&2
            rm -f "$gpg_log"
            exit 1
        fi
        rm -f "$gpg_log"
    else
        echo "==> Aucune signature (.asc) trouvée pour ${archive}."
        if [[ "$require_signature" == "true" ]]; then
            echo "Erreur : --require-signature est activé, signature obligatoire. Abandon." >&2
            exit 1
        fi
        echo "    Poursuite sans vérification de signature (utilisez --require-signature pour l'exiger)."
    fi

    # --- 3. Extraction ---
    local workdir; workdir="$(mktemp -d "/tmp/registry-cli-upload.XXXXXX")"
    trap 'rm -rf "'"$workdir"'"' EXIT
    echo "==> Extraction de l'archive..."
    tar -C "$workdir" -xzf "$archive"
    [[ -d "${workdir}/v2" ]] || { echo "Erreur : l'archive ne contient pas de répertoire v2/." >&2; exit 1; }

    if [[ -f "${workdir}/registrish-archive.json" ]]; then
        echo "==> Métadonnées de l'archive :"
        cat "${workdir}/registrish-archive.json"
    fi

    # --- 4. Fusion dans la registry cible ---
    mkdir -p "${root}/v2"
    echo "==> Fusion de v2/ dans ${root}..."
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${workdir}/v2/" "${root}/v2/"
    else
        echo "    ('rsync' absent, repli sur cp -a)"
        cp -a "${workdir}/v2/." "${root}/v2/"
    fi
    echo "    OK."

    # --- 5. Régénération de la configuration Apache + page index.html ---
    if [[ "$regen_config" == "true" ]]; then
        echo "==> Régénération de v2/.htaccess..."
        regen_apache2_config "$root"
        echo "==> Régénération de la page index.html..."
        regen_index_html "$root"
    fi

    echo
    echo "==> Contenu actuel de la registry :"
    cmd_list -r "$root"
}

# ===========================================================================
# Commande : list
# ===========================================================================
usage_list() {
    cat <<EOF
Usage: ${SCRIPT_NAME} list -r REGISTRY_ROOT [--json]

  -r, --registry-root DIR   Racine filesystem de la registry (obligatoire)
      --json                 Sortie au format JSON au lieu d'un tableau
EOF
}

cmd_list() {
    local root="" as_json="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--registry-root) root="$2"; shift 2 ;;
            --json) as_json="true"; shift ;;
            -h|--help) usage_list; exit 0 ;;
            *) echo "Option inconnue pour 'list' : $1" >&2; exit 1 ;;
        esac
    done
    [[ -n "$root" ]] || { echo "Erreur : -r/--registry-root est obligatoire." >&2; exit 1; }
    [[ -d "${root}/v2" ]] || { echo "Erreur : ${root}/v2 introuvable (registry vide ou invalide)." >&2; exit 1; }

    local rows=()
    local manifest_dir image_dir image_name blobs_dir blob_count tag_file tag_name digest digest_hex size mtime
    local has_sig has_att has_sbom cosign_summary

    while IFS= read -r manifest_dir; do
        image_dir="$(dirname "$manifest_dir")"
        image_name="${image_dir#"${root}"/v2/}"
        blobs_dir="${image_dir}/blobs"
        blob_count=0
        [[ -d "$blobs_dir" ]] && blob_count=$(find "$blobs_dir" -type f | wc -l | tr -d ' ')

        while IFS=$'\t' read -r tag_name tag_file; do
            [[ "$tag_name" == "$NO_TAG_MARKER" ]] && tag_name=""
            digest="sha256:$(sha256sum "$tag_file" | cut -d' ' -f1)"
            digest_hex="${digest#sha256:}"
            mtime="$(date -u -r "$tag_file" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")"
            has_sig="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.sig" ]] && has_sig="true"
            has_att="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.att" ]] && has_att="true"
            has_sbom="false"; [[ -f "${manifest_dir}/sha256-${digest_hex}.sbom" ]] && has_sbom="true"
            # Taille de l'IMAGE (manifeste + blobs référencés + artefacts
            # cosign présents), pas juste celle du fichier JSON du manifeste.
            size="$(manifest_total_size "$tag_file" "$blobs_dir")"
            [[ "$has_sig" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.sig" "$blobs_dir")))
            [[ "$has_att" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.att" "$blobs_dir")))
            [[ "$has_sbom" == "true" ]] && size=$((size + $(manifest_total_size "${manifest_dir}/sha256-${digest_hex}.sbom" "$blobs_dir")))
            cosign_summary=""
            [[ "$has_sig" == "true" ]] && cosign_summary="sig"
            [[ "$has_att" == "true" ]] && cosign_summary="${cosign_summary:+${cosign_summary},}att"
            [[ "$has_sbom" == "true" ]] && cosign_summary="${cosign_summary:+${cosign_summary},}sbom"
            [[ -z "$cosign_summary" ]] && cosign_summary="-"
            rows+=("${image_name}|${tag_name}|${digest}|${cosign_summary}|${has_sig}|${has_att}|${has_sbom}|${blob_count}|${size}|${mtime}")
        done < <(list_manifest_entries "$manifest_dir")
    done < <(find "${root}/v2" -type d -name manifests | sort)

    if [[ "${#rows[@]}" -eq 0 ]]; then
        echo "Aucune image trouvée dans ${root}/v2" >&2
        [[ "$as_json" == "true" ]] && echo "[]"
        return 0
    fi

    if [[ "$as_json" == "true" ]]; then
        echo "["
        local n="${#rows[@]}" i=0
        for row in "${rows[@]}"; do
            IFS='|' read -r image tag digest cosign_summary has_sig has_att has_sbom blobs size mtime <<< "$row"
            i=$((i+1))
            printf '  {"image": "%s", "tag": "%s", "digest": "%s", "signature": %s, "attestation": %s, "sbom": %s, "blobs": %s, "size": %s, "last_modified": "%s"}%s\n' \
                "$image" "$tag" "$digest" "$has_sig" "$has_att" "$has_sbom" "$blobs" "$size" "$mtime" \
                "$([[ $i -lt $n ]] && echo ',')"
        done
        echo "]"
    else
        {
            printf 'IMAGE\tTAG\tDIGEST\tCOSIGN\tBLOBS\tSIZE\tLAST_MODIFIED\n'
            for row in "${rows[@]}"; do
                IFS='|' read -r image tag digest cosign_summary has_sig has_att has_sbom blobs size mtime <<< "$row"
                [[ -z "$tag" ]] && tag="(sans tag)"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$image" "$tag" "$digest" "$cosign_summary" "$blobs" "$size" "$mtime"
            done
        } | if command -v column >/dev/null 2>&1; then
                column -t -s $'\t'
            else
                awk -F'\t' '{
                    for (i=1; i<=NF; i++) { if (length($i) > w[i]) w[i] = length($i) }
                    n++; for (i=1; i<=NF; i++) line[n,i]=$i; cols=NF
                }
                END {
                    for (r=1; r<=n; r++) {
                        for (i=1; i<=cols; i++) printf "%-*s  ", w[i], line[r,i]
                        print ""
                    }
                }'
            fi
    fi
}

# ===========================================================================
# Commande : remove
# ===========================================================================
usage_remove() {
    cat <<EOF
Usage: ${SCRIPT_NAME} remove -r REGISTRY_ROOT --image IMAGE [--tag TAG | --digest DIGEST] [options]

  -r, --registry-root DIR   Racine filesystem de la registry (obligatoire)
      --image IMAGE          Nom de l'image (obligatoire). Recherché d'abord tel quel,
                               puis, si introuvable, sous son nom long canonique
                               (ex: --image alpine trouvera docker.io/library/alpine
                               si c'est sous ce nom qu'elle a été stockée par 'pull').
      --tag TAG               Tag à supprimer.
      --digest DIGEST         Digest exact à supprimer (avec ou sans préfixe "sha256:"),
                               cible directement manifests/sha256:xxx plutôt qu'un tag.
                               Mutuellement exclusif avec --tag. Si un tag existant
                               pointe encore vers ce digest, un avertissement est
                               affiché (le tag restera lisible par son nom, mais plus
                               par ce digest précis).
                               Si ni --tag ni --digest ne sont donnés, l'image
                               ENTIÈRE est supprimée.
      --gc                    Nettoie les manifests/blobs de cette image devenus
                               orphelins (les blobs sont stockés par image, donc ce
                               nettoyage n'affecte jamais les autres images).
                               Activé par défaut ; utilisez --no-gc pour désactiver.
      --no-gc                 Désactive le nettoyage des orphelins.
      --purge-if-empty        S'il ne reste plus aucun tag après la suppression,
                               supprime aussi le répertoire de l'image.
                               Activé par défaut ; utilisez --no-purge-if-empty pour
                               désactiver.
      --no-purge-if-empty     Désactive la purge automatique du répertoire vide.
  -y, --yes                   Ne pas demander de confirmation
      --dry-run                Simule l'opération sans rien supprimer
      --regen-config           Régénère v2/.htaccess après suppression (défaut : activé)
      --no-regen-config        Désactive la régénération de v2/.htaccess

Exemples :
  ${SCRIPT_NAME} remove -r /srv/registrish --image alpine --tag 3.19
  ${SCRIPT_NAME} remove -r /srv/registrish --image alpine --digest sha256:abcd...
  ${SCRIPT_NAME} remove -r /srv/registrish --image library/nginx -y
  ${SCRIPT_NAME} remove -r /srv/registrish --image alpine --tag 3.19 --no-gc --no-purge-if-empty
EOF
}

declare -A _GC_VISITED
_GC_REACHABLE_MANIFESTS=()
_GC_REACHABLE_BLOBS=()

_gc_visit() {
    local digest="$1" manifests_dir="$2" blobs_dir="$3"
    [[ -n "${_GC_VISITED[$digest]:-}" ]] && return
    _GC_VISITED[$digest]=1
    if [[ -f "${manifests_dir}/sha256:${digest}" ]]; then
        _GC_REACHABLE_MANIFESTS+=("sha256:${digest}")
        local d
        while IFS= read -r d; do
            [[ -n "$d" ]] && _gc_visit "$d" "$manifests_dir" "$blobs_dir"
        done < <(extract_referenced_digests "${manifests_dir}/sha256:${digest}")
    elif [[ -f "${blobs_dir}/sha256:${digest}" ]]; then
        _GC_REACHABLE_BLOBS+=("sha256:${digest}")
    fi
}

gc_image() {
    local image_dir="$1" dry_run="$2" exclude_tag="${3:-}"
    local manifests_dir="${image_dir}/manifests" blobs_dir="${image_dir}/blobs"

    _GC_VISITED=()
    _GC_REACHABLE_MANIFESTS=()
    _GC_REACHABLE_BLOBS=()

    local tag_file digest tag_base d
    while IFS= read -r tag_file; do
        tag_base="$(basename "$tag_file")"
        [[ -n "$exclude_tag" && "$tag_base" == "$exclude_tag" ]] && continue
        digest="$(sha256sum "$tag_file" | cut -d' ' -f1)"
        # Marque ce digest racine comme atteignable en lisant DIRECTEMENT le
        # contenu du fichier de tag (qui existe toujours à ce stade), sans
        # dépendre de la présence du fichier canonique manifests/sha256:xxx
        # correspondant — celui-ci a pu être supprimé indépendamment via
        # 'remove --digest' tout en laissant le tag (fichier séparé, même
        # contenu) intact. Sinon, les blobs encore utilisés par ce tag
        # seraient à tort nettoyés comme orphelins.
        if [[ -z "${_GC_VISITED[$digest]:-}" ]]; then
            _GC_VISITED[$digest]=1
            _GC_REACHABLE_MANIFESTS+=("sha256:${digest}")
            while IFS= read -r d; do
                [[ -n "$d" ]] && _gc_visit "$d" "$manifests_dir" "$blobs_dir"
            done < <(extract_referenced_digests "$tag_file")
        fi
    done < <(find "$manifests_dir" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null)

    local removed_manifests=0 removed_blobs=0 f base is_reachable m

    if [[ -d "$manifests_dir" ]]; then
        while IFS= read -r f; do
            base="$(basename "$f")"
            is_reachable="false"
            for m in "${_GC_REACHABLE_MANIFESTS[@]}"; do
                [[ "$m" == "$base" ]] && { is_reachable="true"; break; }
            done
            if [[ "$is_reachable" == "false" ]]; then
                removed_manifests=$((removed_manifests + 1))
                if [[ "$dry_run" == "true" ]]; then
                    echo "    [dry-run] manifest orphelin : $f"
                else
                    rm -f "$f"
                fi
            fi
        done < <(find "$manifests_dir" -maxdepth 1 -type f -name 'sha256:*' 2>/dev/null)
    fi

    if [[ -d "$blobs_dir" ]]; then
        while IFS= read -r f; do
            base="$(basename "$f")"
            is_reachable="false"
            for m in "${_GC_REACHABLE_BLOBS[@]}"; do
                [[ "$m" == "$base" ]] && { is_reachable="true"; break; }
            done
            if [[ "$is_reachable" == "false" ]]; then
                removed_blobs=$((removed_blobs + 1))
                if [[ "$dry_run" == "true" ]]; then
                    echo "    [dry-run] blob orphelin : $f"
                else
                    rm -f "$f"
                fi
            fi
        done < <(find "$blobs_dir" -maxdepth 1 -type f -name 'sha256:*' 2>/dev/null)
    fi

    local verb="supprimé(s)"
    [[ "$dry_run" == "true" ]] && verb="à supprimer (simulation)"
    echo "    GC : ${removed_manifests} manifest(s) et ${removed_blobs} blob(s) orphelin(s) ${verb}."
}

cmd_remove() {
    local root="" image="" tag="" digest="" gc="true" yes="false" dry_run="false"
    local purge_if_empty="true" regen_config="true"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--registry-root) root="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --tag) tag="$2"; shift 2 ;;
            --digest) digest="$2"; shift 2 ;;
            --gc) gc="true"; shift ;;
            --no-gc) gc="false"; shift ;;
            --purge-if-empty) purge_if_empty="true"; shift ;;
            --no-purge-if-empty) purge_if_empty="false"; shift ;;
            -y|--yes) yes="true"; shift ;;
            --dry-run) dry_run="true"; shift ;;
            --regen-config) regen_config="true"; shift ;;
            --no-regen-config) regen_config="false"; shift ;;
            -h|--help) usage_remove; exit 0 ;;
            *) echo "Option inconnue pour 'remove' : $1" >&2; exit 1 ;;
        esac
    done

    [[ -n "$root" ]] || { echo "Erreur : -r/--registry-root est obligatoire." >&2; exit 1; }
    [[ -n "$image" ]] || { echo "Erreur : --image est obligatoire." >&2; exit 1; }
    if [[ -n "$tag" && -n "$digest" ]]; then
        echo "Erreur : --tag et --digest sont mutuellement exclusifs." >&2
        exit 1
    fi
    local image_dir="${root}/v2/${image}"
    if [[ ! -d "$image_dir" ]]; then
        local expanded_image
        expanded_image="$(normalize_image_name "$image")"
        if [[ "$expanded_image" != "$image" && -d "${root}/v2/${expanded_image}" ]]; then
            echo "==> Image étendue au format long : ${image} -> ${expanded_image}"
            image="$expanded_image"
            image_dir="${root}/v2/${image}"
        fi
    fi
    [[ -d "$image_dir" ]] || { echo "Erreur : image introuvable : ${image} (${image_dir})" >&2; exit 1; }

    local digest_full=""
    [[ -n "$digest" ]] && digest_full="$(normalize_digest "$digest")"

    if [[ -z "$tag" && -z "$digest_full" ]]; then
        # --- Suppression complète de l'image ---
        local n_tags n_blobs
        n_tags=$(find "${image_dir}/manifests" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null | wc -l | tr -d ' ')
        n_blobs=$(find "${image_dir}/blobs" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "Cible : image '${image}' (${image_dir}) — ${n_tags} tag(s), ${n_blobs} blob(s)."
        confirm_or_abort "$yes" "Supprimer définitivement l'image '${image}' et tout son contenu ?"
        if [[ "$dry_run" == "true" ]]; then
            echo "[dry-run] supprimerait : $image_dir"
        else
            rm -rf "$image_dir"
            echo "Image '${image}' supprimée."
        fi
    else
        # --- Suppression d'un tag ou d'un digest précis ---
        local manifest_file exclude_tag_for_gc=""
        if [[ -n "$tag" ]]; then
            manifest_file="${image_dir}/manifests/${tag}"
            [[ -f "$manifest_file" ]] || { echo "Erreur : tag introuvable : ${image}:${tag}" >&2; exit 1; }
            exclude_tag_for_gc="$tag"
            confirm_or_abort "$yes" "Supprimer le tag '${image}:${tag}' ?"
        else
            manifest_file="${image_dir}/manifests/${digest_full}"
            [[ -f "$manifest_file" ]] || { echo "Erreur : digest introuvable dans '${image}' : ${digest_full}" >&2; exit 1; }

            # Avertissement de sécurité : ce digest est-il encore référencé
            # par un tag actuellement vivant (directement ou via une
            # manifest-list) ? Si oui, le supprimer cassera la résolution
            # par digest de ce contenu, même si le tag continuera de
            # fonctionner par lui-même (fichier indépendant).
            _GC_VISITED=(); _GC_REACHABLE_MANIFESTS=(); _GC_REACHABLE_BLOBS=()
            local tf tdg
            while IFS= read -r tf; do
                tdg="$(sha256sum "$tf" | cut -d' ' -f1)"
                _gc_visit "$tdg" "${image_dir}/manifests" "${image_dir}/blobs"
            done < <(find "${image_dir}/manifests" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null)
            local m referenced="false"
            for m in "${_GC_REACHABLE_MANIFESTS[@]}"; do
                [[ "$m" == "$digest_full" ]] && { referenced="true"; break; }
            done
            if [[ "$referenced" == "true" ]]; then
                echo "⚠ Attention : ${digest_full} est encore référencé par au moins un tag existant de '${image}'." >&2
                echo "  Le supprimer cassera le pull par ce digest précis (le(s) tag(s) concerné(s) resteront pullables par leur nom)." >&2
            fi

            confirm_or_abort "$yes" "Supprimer le digest '${image}@${digest_full}' ?"
        fi

        if [[ "$dry_run" == "true" ]]; then
            echo "[dry-run] supprimerait : $manifest_file"
        else
            rm -f "$manifest_file"
            echo "'${manifest_file##*/}' supprimé de '${image}'."
        fi

        if [[ "$gc" == "true" ]]; then
            echo "Nettoyage des manifests/blobs orphelins pour '${image}'..."
            gc_image "$image_dir" "$dry_run" "$exclude_tag_for_gc"
        fi

        local remaining=0 f
        while IFS= read -r f; do
            [[ "$f" == "$manifest_file" ]] && continue
            remaining=$((remaining + 1))
        done < <(find "${image_dir}/manifests" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null)

        if [[ "$remaining" -eq 0 ]]; then
            echo "Il ne reste plus aucun tag pour l'image '${image}'."
            if [[ "$purge_if_empty" == "true" ]]; then
                confirm_or_abort "$yes" "Purger entièrement le répertoire (désormais vide) de '${image}' ?"
                if [[ "$dry_run" == "true" ]]; then
                    echo "[dry-run] supprimerait : $image_dir"
                else
                    rm -rf "$image_dir"
                    echo "Répertoire d'image '${image}' purgé."
                fi
            else
                echo "  (utilisez --purge-if-empty, ou retirez --no-purge-if-empty, pour aussi supprimer le répertoire vide)"
            fi
        fi
    fi

    if [[ "$regen_config" == "true" && "$dry_run" == "false" ]]; then
        echo "==> Régénération de v2/.htaccess..."
        regen_apache2_config "$root"
        echo "==> Régénération de la page index.html..."
        regen_index_html "$root"
    fi

    echo
    echo "==> Contenu actuel de la registry :"
    cmd_list -r "$root"
}

# ===========================================================================
# Commande : index
# ===========================================================================
usage_index() {
    cat <<EOF
Usage: ${SCRIPT_NAME} index -r REGISTRY_ROOT

Régénère uniquement la page index.html à la racine de la registry (tableau
de bord statique et autonome des images/tags/architectures disponibles),
sans toucher au reste (v2/.htaccess, error.json...). Utile après une
modification manuelle de la registry, ou pour la générer une première fois
sur une registry qui n'en a pas encore.

Cette page est régénérée automatiquement par 'upload' et 'remove' (sauf
--no-regen-config) ; cette commande sert pour les cas où vous voulez la
regénérer sans déclencher une autre opération.

  -r, --registry-root DIR   Racine filesystem de la registry (obligatoire)

Exemple :
  ${SCRIPT_NAME} index -r /srv/registrish
EOF
}

cmd_index() {
    local root=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--registry-root) root="$2"; shift 2 ;;
            -h|--help) usage_index; exit 0 ;;
            *) echo "Option inconnue pour 'index' : $1" >&2; exit 1 ;;
        esac
    done
    [[ -n "$root" ]] || { echo "Erreur : -r/--registry-root est obligatoire." >&2; exit 1; }
    [[ -d "$root" ]] || { echo "Erreur : répertoire introuvable : $root" >&2; exit 1; }

    echo "==> Régénération de la page index.html..."
    regen_index_html "$root"
}

# ===========================================================================
# Commande : verify
#
# Vérifie une signature cosign. Contrairement à toutes les autres commandes,
# 'verify' ne touche JAMAIS un chemin local : cosign parle le protocole HTTP
# "OCI Distribution" (GET /v2/<name>/manifests/<ref>, etc.), donc la cible
# est forcément l'URL où v2/ est réellement SERVI (Apache2), construite comme
# "${registry_url}/${image}:${tag}" (ou "@${digest}").
#
# Volontairement limité à la vérification par CLÉ PUBLIQUE (pas de mode
# "keyless" Rekor/Fulcio) : c'est le seul mode compatible avec l'usage 100%
# offline de cet outil, la vérification keyless nécessitant un accès réseau
# à la transparence Sigstore publique au moment même de la vérification.
# ===========================================================================
usage_verify() {
    cat <<EOF
Usage: ${SCRIPT_NAME} verify -u REGISTRY_URL -i IMAGE (-t TAG | -d DIGEST) -k CLE_PUBLIQUE [options] [-- ARGS_COSIGN...]

Options obligatoires :
  -u, --registry-url HOTE[:PORT]  Hôte de la registry telle que SERVIE en
                                    HTTP(S) (ex: registry.example.com,
                                    localhost:8080) -- PAS le chemin
                                    filesystem local (REGISTRY_ROOT) : cosign
                                    a besoin de parler le protocole HTTP de
                                    la registry, pas de lire des fichiers.
  -i, --image IMAGE                Nom de l'image (voir 'pull --help' pour la
                                     normalisation automatique en nom long)
  -t, --tag TAG | -d, --digest DIGEST   Référence à vérifier (exclusifs)
  -k, --key FICHIER                 Clé publique cosign (cosign.pub). Seule
                                     la vérification par clé est supportée
                                     ici (voir la note en tête de fichier).

Options :
      --no-expand                   Ne pas étendre -i/--image au format long
  -- ARGS_COSIGN...                 Arguments cosign supplémentaires transmis
                                     tels quels en fin de ligne (ex: options
                                     TLS/insecure spécifiques à votre version
                                     de cosign pour un registre HTTP simple)

Exemple :
  ${SCRIPT_NAME} verify -u registry.example.com -i alpine -t 3.20 -k cosign.pub
EOF
}

cmd_verify() {
    local registry_url="" image="" tag="" digest="" key="" no_expand="false"
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--registry-url) registry_url="$2"; shift 2 ;;
            -i|--image) image="$2"; shift 2 ;;
            -t|--tag) tag="$2"; shift 2 ;;
            -d|--digest) digest="$2"; shift 2 ;;
            -k|--key) key="$2"; shift 2 ;;
            --no-expand) no_expand="true"; shift ;;
            -h|--help) usage_verify; exit 0 ;;
            --) shift; extra_args=("$@"); break ;;
            *) echo "Option inconnue pour 'verify' : $1" >&2; exit 1 ;;
        esac
    done

    [[ -n "$registry_url" ]] || { echo "Erreur : -u/--registry-url est obligatoire." >&2; usage_verify; exit 1; }
    [[ -n "$image" ]] || { echo "Erreur : -i/--image est obligatoire." >&2; usage_verify; exit 1; }
    [[ -n "$key" ]] || { echo "Erreur : -k/--key (clé publique cosign) est obligatoire." >&2; usage_verify; exit 1; }
    [[ -f "$key" ]] || { echo "Erreur : clé publique introuvable : $key" >&2; exit 1; }
    if [[ -n "$tag" && -n "$digest" ]]; then
        echo "Erreur : --tag et --digest sont mutuellement exclusifs." >&2
        exit 1
    fi
    [[ -n "$tag" || -n "$digest" ]] || { echo "Erreur : précisez -t/--tag ou -d/--digest." >&2; usage_verify; exit 1; }

    command -v cosign >/dev/null 2>&1 || { echo "Erreur : 'cosign' est requis pour 'verify'." >&2; exit 1; }

    if [[ "$no_expand" == "false" ]]; then
        local expanded_image
        expanded_image="$(normalize_image_name "$image")"
        if [[ "$expanded_image" != "$image" ]]; then
            echo "==> Image étendue au format long : ${image} -> ${expanded_image}"
            image="$expanded_image"
        fi
    fi

    local digest_full=""
    [[ -n "$digest" ]] && digest_full="$(normalize_digest "$digest")"

    local ref
    if [[ -n "$digest_full" ]]; then
        ref="${registry_url}/${image}@${digest_full}"
    else
        ref="${registry_url}/${image}:${tag}"
    fi

    echo "==> Vérification de la signature cosign de ${ref} (clé : ${key})..."
    cosign verify --key "$key" "${extra_args[@]}" "$ref"
}

# ===========================================================================
# Commande : sbom
#
# Extrait un SBOM (par défaut CycloneDX) attaché à une image sous forme
# d'attestation in-toto cosign (DSSE), en JSON brut -- le SBOM lui-même, pas
# l'enveloppe de signature qui l'entoure. Même remarque que 'verify' : la
# cible est l'URL HTTP où la registry est servie, pas un chemin local.
# ===========================================================================
usage_sbom() {
    cat <<EOF
Usage: ${SCRIPT_NAME} sbom -u REGISTRY_URL -i IMAGE (-t TAG | -d DIGEST) [options] [-- ARGS_COSIGN...]

Options obligatoires :
  -u, --registry-url HOTE[:PORT]   Hôte de la registry SERVIE en HTTP(S)
                                     (voir 'verify --help')
  -i, --image IMAGE
  -t, --tag TAG | -d, --digest DIGEST   Référence ciblée (exclusifs)

Options :
  -k, --key FICHIER          Clé publique cosign : si fournie, l'attestation
                               est VÉRIFIÉE (cosign verify-attestation) avant
                               extraction. Sans -k, l'attestation est
                               seulement TÉLÉCHARGÉE SANS AUCUNE VÉRIFICATION
                               (cosign download attestation) -- à réserver à
                               l'inspection, pas à un usage de confiance.
      --type TYPE              Type de prédicat in-toto ciblé (défaut :
                                 cyclonedx). Voir 'cosign verify-attestation
                                 --help'/'cosign download attestation --help'
                                 pour les types reconnus par votre version.
  -o, --output FICHIER         Fichier de sortie (défaut : stdout)
      --no-expand                Ne pas étendre -i/--image au format long
  -- ARGS_COSIGN...              Arguments cosign supplémentaires transmis
                                  tels quels en fin de ligne

Dépendance supplémentaire : 'jq' est OBLIGATOIRE pour cette commande (pas de
repli grep/sed : décoder correctement une enveloppe DSSE base64 imbriquée
sans risquer de corrompre le SBOM nécessite un vrai parseur JSON).

En cas d'attestations multiples du même type pour cette image, seule la
première est extraite.

Exemple :
  ${SCRIPT_NAME} sbom -u registry.example.com -i alpine -t 3.20 -k cosign.pub -o alpine-3.20.cdx.json
EOF
}

cmd_sbom() {
    local registry_url="" image="" tag="" digest="" key="" sbom_type="cyclonedx"
    local output="" no_expand="false"
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--registry-url) registry_url="$2"; shift 2 ;;
            -i|--image) image="$2"; shift 2 ;;
            -t|--tag) tag="$2"; shift 2 ;;
            -d|--digest) digest="$2"; shift 2 ;;
            -k|--key) key="$2"; shift 2 ;;
            --type) sbom_type="$2"; shift 2 ;;
            -o|--output) output="$2"; shift 2 ;;
            --no-expand) no_expand="true"; shift ;;
            -h|--help) usage_sbom; exit 0 ;;
            --) shift; extra_args=("$@"); break ;;
            *) echo "Option inconnue pour 'sbom' : $1" >&2; exit 1 ;;
        esac
    done

    [[ -n "$registry_url" ]] || { echo "Erreur : -u/--registry-url est obligatoire." >&2; usage_sbom; exit 1; }
    [[ -n "$image" ]] || { echo "Erreur : -i/--image est obligatoire." >&2; usage_sbom; exit 1; }
    if [[ -n "$tag" && -n "$digest" ]]; then
        echo "Erreur : --tag et --digest sont mutuellement exclusifs." >&2
        exit 1
    fi
    [[ -n "$tag" || -n "$digest" ]] || { echo "Erreur : précisez -t/--tag ou -d/--digest." >&2; usage_sbom; exit 1; }

    command -v cosign >/dev/null 2>&1 || { echo "Erreur : 'cosign' est requis pour 'sbom'." >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "Erreur : 'jq' est requis pour 'sbom' (extraction fiable du SBOM depuis l'enveloppe DSSE)." >&2; exit 1; }

    if [[ -n "$key" ]]; then
        [[ -f "$key" ]] || { echo "Erreur : clé publique introuvable : $key" >&2; exit 1; }
    fi

    if [[ "$no_expand" == "false" ]]; then
        local expanded_image
        expanded_image="$(normalize_image_name "$image")"
        if [[ "$expanded_image" != "$image" ]]; then
            echo "==> Image étendue au format long : ${image} -> ${expanded_image}"
            image="$expanded_image"
        fi
    fi

    local digest_full=""
    [[ -n "$digest" ]] && digest_full="$(normalize_digest "$digest")"

    local ref
    if [[ -n "$digest_full" ]]; then
        ref="${registry_url}/${image}@${digest_full}"
    else
        ref="${registry_url}/${image}:${tag}"
    fi

    local envelope
    if [[ -n "$key" ]]; then
        echo "==> Vérification de l'attestation '${sbom_type}' de ${ref} (clé : ${key})..." >&2
        envelope="$(cosign verify-attestation --key "$key" --type "$sbom_type" "${extra_args[@]}" "$ref")" \
            || { echo "Erreur : vérification de l'attestation échouée." >&2; exit 1; }
    else
        echo "==> Aucune clé fournie : téléchargement SANS VÉRIFICATION de l'attestation '${sbom_type}' de ${ref}..." >&2
        envelope="$(cosign download attestation --predicate-type "$sbom_type" "${extra_args[@]}" "$ref")" \
            || { echo "Erreur : téléchargement de l'attestation échoué." >&2; exit 1; }
    fi

    local sbom_json
    sbom_json="$(printf '%s\n' "$envelope" \
        | jq -r 'select(.payloadType == "application/vnd.in-toto+json") | .payload' \
        | head -n1)"
    [[ -n "$sbom_json" ]] || {
        echo "Erreur : aucune enveloppe d'attestation in-toto exploitable dans la réponse de cosign." >&2
        exit 1
    }
    sbom_json="$(printf '%s' "$sbom_json" | base64 -d 2>/dev/null | jq '.predicate')" \
        || { echo "Erreur : impossible de décoder/parser le contenu de l'attestation." >&2; exit 1; }
    [[ -n "$sbom_json" && "$sbom_json" != "null" ]] || {
        echo "Erreur : l'attestation ne contient pas de champ 'predicate' exploitable." >&2
        exit 1
    }

    if [[ -n "$output" ]]; then
        printf '%s\n' "$sbom_json" > "$output"
        echo "==> SBOM écrit dans ${output}"
    else
        printf '%s\n' "$sbom_json"
    fi
}

# ===========================================================================
# Commande : completion
# ===========================================================================
# Affiche le script d'auto-complétion bash. Embarqué directement ici pour
# que registry-cli.sh reste un fichier UNIQUE et autonome : pas de second
# fichier à distribuer, pas de risque de désynchronisation entre le script
# et sa complétion (une seule source de vérité).
cmd_completion() {
    cat <<'COMPLETION_EOF'
#!/usr/bin/env bash
#
# Auto-complétion bash pour registry-cli.sh
# Généré par : registry-cli.sh completion
#
# Installation temporaire :
#   source <(registry-cli.sh completion)
#
# Installation permanente :
#   registry-cli.sh completion | sudo tee /etc/bash_completion.d/registry-cli > /dev/null
# ou, sans droits root :
#   mkdir -p ~/.local/share/bash-completion/completions
#   registry-cli.sh completion > ~/.local/share/bash-completion/completions/registry-cli
#

_registry_cli_commands="pull upload list remove index verify sbom completion"

_registry_cli_find_opt_value() {
    local opt_list="$1" opt i
    for opt in $opt_list; do
        for ((i = 1; i < ${#COMP_WORDS[@]}; i++)); do
            if [[ "${COMP_WORDS[i]}" == "$opt" ]]; then
                printf '%s' "${COMP_WORDS[i + 1]:-}"
                return 0
            fi
        done
    done
    return 1
}

_registry_cli_list_images() {
    local root="$1"
    [[ -d "${root}/v2" ]] || return 0
    local d
    while IFS= read -r d; do
        d="${d#"${root}"/v2/}"
        printf '%s\n' "${d%/manifests}"
    done < <(find "${root}/v2" -type d -name manifests 2>/dev/null)
}

_registry_cli_list_tags() {
    local root="$1" image="$2"
    local mdir="${root}/v2/${image}/manifests"
    [[ -d "$mdir" ]] || return 0
    find "$mdir" -maxdepth 1 -type f ! -name 'sha256:*' ! -name '.htaccess' 2>/dev/null \
        -exec basename {} \;
}

_registry_cli_complete() {
    local cur prev cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    cmd="${COMP_WORDS[1]:-}"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${_registry_cli_commands} -h --help --version" -- "$cur") )
        return 0
    fi

    case "$prev" in
        -o|--output|-a|--archive|-k|--gpg-key|--gpg-keyring)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        -r|--registry-root|--from-dir)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        --source)
            COMPREPLY=( $(compgen -W "docker:// docker-daemon: containers-storage:" -- "$cur") )
            return 0
            ;;
        --arch)
            COMPREPLY=( $(compgen -W "amd64 arm64 arm 386 ppc64le s390x all" -- "$cur") )
            return 0
            ;;
        --os)
            COMPREPLY=( $(compgen -W "linux windows" -- "$cur") )
            return 0
            ;;
        -i|--image)
            local root
            root="$(_registry_cli_find_opt_value '-r --registry-root')"
            if [[ -n "$root" ]]; then
                COMPREPLY=( $(compgen -W "$(_registry_cli_list_images "$root")" -- "$cur") )
            fi
            return 0
            ;;
        -t|--tag)
            local root image
            root="$(_registry_cli_find_opt_value '-r --registry-root')"
            image="$(_registry_cli_find_opt_value '-i --image')"
            if [[ -n "$root" && -n "$image" ]]; then
                COMPREPLY=( $(compgen -W "$(_registry_cli_list_tags "$root" "$image")" -- "$cur") )
            fi
            return 0
            ;;
        -d|--digest)
            return 0
            ;;
    esac

    local opts=""
    case "$cmd" in
        pull)
            opts="-i --image -t --tag -d --digest -o --output -k --gpg-key --from-dir --source --arch --os --keep-workdir --with-signatures --sig-from-dir --att-from-dir --sbom-from-dir -h --help"
            ;;
        upload)
            opts="-a --archive -r --registry-root --regen-config --no-regen-config --require-signature --skip-checksum --gpg-keyring -h --help"
            ;;
        list)
            opts="-r --registry-root --json -h --help"
            ;;
        remove)
            opts="-r --registry-root --image --tag --digest --gc --no-gc --purge-if-empty --no-purge-if-empty -y --yes --dry-run --regen-config --no-regen-config -h --help"
            ;;
        index)
            opts="-r --registry-root -h --help"
            ;;
        verify)
            opts="-u --registry-url -i --image -t --tag -d --digest -k --key --no-expand -h --help"
            ;;
        sbom)
            opts="-u --registry-url -i --image -t --tag -d --digest -k --key --type -o --output --no-expand -h --help"
            ;;
        *)
            opts="-h --help"
            ;;
    esac

    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
}

complete -F _registry_cli_complete registry-cli.sh
complete -F _registry_cli_complete ./registry-cli.sh
complete -F _registry_cli_complete registry-cli
COMPLETION_EOF
}

# ---------------------------------------------------------------------------
# Point d'entrée
#
# Protégé par ce test (idiome bash standard) pour que le script puisse aussi
# être sourcé (ex: `source registry-cli.sh` depuis une suite de tests) sans
# déclencher l'exécution d'une commande : le point d'entrée ne s'exécute que
# lorsque le fichier est lancé directement (./registry-cli.sh ...).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--version" ]]; then
        echo "registry-cli.sh version ${REGISTRY_CLI_VERSION}"
        exit 0
    fi

    [[ $# -ge 1 ]] || { usage; exit 1; }
    COMMAND="$1"; shift

    for bin in sha256sum find grep sed; do
        command -v "$bin" >/dev/null 2>&1 || { echo "Erreur : '$bin' est requis mais introuvable." >&2; exit 1; }
    done

    case "$COMMAND" in
        pull) cmd_pull "$@" ;;
        upload) cmd_upload "$@" ;;
        list) cmd_list "$@" ;;
        remove) cmd_remove "$@" ;;
        index) cmd_index "$@" ;;
        verify) cmd_verify "$@" ;;
        sbom) cmd_sbom "$@" ;;
        completion) cmd_completion "$@" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Commande inconnue : $COMMAND" >&2; usage; exit 1 ;;
    esac
fi
