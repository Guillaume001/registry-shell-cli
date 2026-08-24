# registry-cli.sh

Outil unique et **100% autonome (offline)** pour gérer une registry Docker
statique au format [registrish](https://github.com/jpetazzo/registrish)
(une arborescence `v2/<image>/{blobs,manifests}` servable par n'importe quel
hébergeur de fichiers statiques — Apache2, NGINX, Netlify, S3...).

Ce script ne clone **jamais** de dépôt distant et ne dépend d'aucun script
externe. La conversion `skopeo dir:` → arborescence registry et la
génération de la configuration Apache sont des traductions fidèles en bash
de `dir2reg.sh` et `gen-apache2.sh` du dépôt `jpetazzo/registrish`.

## Sommaire

- [Dépendances](#dépendances)
- [Installation](#installation)
- [Auto-complétion](#auto-complétion)
- [Concepts](#concepts)
- [Commandes](#commandes)
  - [pull](#pull--télécharger-une-image-et-produire-une-archive)
  - [upload](#upload--placer-une-archive-dans-la-registry)
  - [list](#list--inventaire-de-la-registry)
  - [remove](#remove--supprimer-un-tag-un-digest-ou-une-image)
  - [index](#index--page-daccueil-html-de-la-registry)
  - [verify](#verify--vérifier-une-signature-cosign)
  - [sbom](#sbom--extraire-un-sbom-cyclonedx)
  - [completion](#auto-complétion)
- [Signatures et SBOM (cosign)](#signatures-et-sbom-cosign)
- [Format de l'archive](#format-de-larchive)
- [Structure de la registry produite](#structure-de-la-registry-produite)
- [Workflows type](#workflows-type)
- [Notes et limites connues](#notes-et-limites-connues)

## Dépendances

| Outil       | Requis pour                                              | Obligatoire ?                  |
|-------------|-----------------------------------------------------------|---------------------------------|
| `bash`      | tout                                                       | oui                              |
| `tar`, `sha256sum`, `grep`, `sed`, `find` | tout                                   | oui (présents sur tout Linux)   |
| `skopeo`    | `pull` sans `--from-dir`                                   | non si `--from-dir` utilisé     |
| `gpg`       | signer (`pull -k`) ou vérifier une signature (`upload`)    | non si pas de signature en jeu  |
| `rsync`     | `upload` (fusion des fichiers)                              | non — repli automatique sur `cp -a` |
| `jq`        | `upload`/`remove` (lecture du `mediaType` des manifestes)   | non — repli automatique par `grep`/`sed` (sauf `sbom`, voir ci-dessous) |
| `column`    | `list` (affichage en tableau aligné)                        | non — repli par `awk`           |
| `cosign`    | `verify`, `sbom`                                             | **oui**, pas de repli — ces commandes parlent directement le protocole cosign |
| `jq` (pour `sbom`) | `sbom` (décodage de l'enveloppe DSSE base64 imbriquée) | **oui pour `sbom` uniquement**, pas de repli grep/sed (risque de corrompre le SBOM) |

Aucune de ces dépendances optionnelles ne bloque le script si elle est
absente : un repli en bash pur est utilisé automatiquement, avec un message
l'indiquant.

## Installation

```bash
chmod +x registry-cli.sh
# Utilisable directement :
./registry-cli.sh --help

# Ou installé dans le PATH :
sudo cp registry-cli.sh /usr/local/bin/registry-cli
```

## Auto-complétion

`registry-cli.sh` est un **fichier unique et auto-suffisant** : la
complétion bash est embarquée directement dans le script (sous-commande
`completion`), pas besoin de fichier séparé à distribuer. Elle complète
les sous-commandes, les options de chaque sous-commande, et même les
**noms d'images et de tags existants** en inspectant dynamiquement la
registry ciblée par `-r/--registry-root` quand elle est déjà présente sur
la ligne de commande.

Installation temporaire (session courante) :

```bash
source <(registry-cli.sh completion)
```

Installation permanente :

```bash
# Linux (bash-completion v2)
registry-cli.sh completion | sudo tee /etc/bash_completion.d/registry-cli > /dev/null

# ou, sans droits root, pour l'utilisateur courant :
mkdir -p ~/.local/share/bash-completion/completions
registry-cli.sh completion > ~/.local/share/bash-completion/completions/registry-cli
```

Puis ouvrez un nouveau terminal (ou `source ~/.bashrc`).

Si vous avez renommé le script (ex: `registry-cli` sans extension), la
complétion fonctionne aussi automatiquement car elle s'enregistre pour tout
programme nommé `registry-cli.sh`, `registry-cli`, ou `./registry-cli.sh`.

`registry-cli.sh --version` affiche la version du script.

## Concepts

- **Archive** : un `.tar.gz` produit par `pull`, contenant une arborescence
  `v2/<image>/{blobs,manifests}` prête à fusionner dans une registry, plus
  un fichier `registrish-archive.json` de métadonnées (image, tag, digest,
  architecture, date). Toujours accompagnée d'un `.sha256`, et
  optionnellement d'une signature GPG détachée (`.asc`).
- **Registry** : un répertoire filesystem (`REGISTRY_ROOT`) contenant
  `v2/<image>/{blobs,manifests}` pour une ou plusieurs images, plus
  `v2/error.json` et des fichiers `.htaccess` pour Apache2.
- **Tag vs digest** : dans cette arborescence, un tag (ex: `3.20`) est une
  **copie indépendante** du contenu du manifeste, nommée par son tag. Le
  fichier canonique `manifests/sha256:<digest>` est une copie du même
  contenu, nommée par son digest. Les deux coexistent et sont décorrélés :
  supprimer l'un ne supprime pas l'autre (voir [remove](#remove--supprimer-un-tag-un-digest-ou-une-image)).
  Une image récupérée avec `pull -d ...` **sans** `-t` n'a que le fichier
  canonique, aucun tag : `list`/`index` l'affichent quand même, avec un tag
  vide (`(sans tag)` en texte, `""` en JSON).
- **Nom d'image long (canonique)** : `pull` étend automatiquement un nom
  court/ambigu vers son nom long, pour toujours savoir sans ambiguïté d'où
  vient l'image (mêmes règles que Docker/Podman en interne) :
  - `alpine` → `docker.io/library/alpine`
  - `dxflrs/garage` → `docker.io/dxflrs/garage`
  - `quay.io/foo/bar`, `localhost/foo`, `localhost:5000/foo` → inchangés
    (déjà qualifiés : premier segment contenant un `.`, un `:`, ou égal à
    `localhost`)
  Désactivable avec `--no-expand` sur `pull`. `remove --image` recherche
  d'abord le nom tel quel, puis son équivalent étendu si introuvable — donc
  `remove --image alpine` retrouve `docker.io/library/alpine`.
- **Artefact cosign (signature/attestation/SBOM)** : cosign ne stocke pas
  ces objets ailleurs que dans le même dépôt que l'image, sous forme de
  **tags supplémentaires ordinaires** : `sha256-<digest>.sig` (signature),
  `sha256-<digest>.att` (attestation in-toto, peut embarquer un SBOM
  CycloneDX), `sha256-<digest>.sbom` (SBOM legacy), ou le tag de repli
  statique OCI 1.1 `sha256-<digest>` (index listant les manifestes qui
  référencent l'image, utilisé quand la registry ne supporte pas l'API
  Referrers dynamique — le cas ici, Apache2 ne servant que du statique).
  Comme ce sont de simples tags, ils transitent par le même mécanisme que
  n'importe quel autre tag (voir [pull --with-signatures](#signatures-et-sbom-cosign)).

## Commandes

### `pull` — télécharger une image et produire une archive

```
registry-cli.sh pull -i IMAGE (-t TAG | -d DIGEST) [-o ARCHIVE.tar.gz] [options]
registry-cli.sh pull -i IMAGE [-t TAG] [-d DIGEST] [-o ARCHIVE.tar.gz] --from-dir DIR
```

| Option | Description |
|---|---|
| `-i`, `--image IMAGE` | **Obligatoire.** Nom de l'image (ex: `alpine`, `library/nginx`). |
| `-t`, `--tag TAG` | Tag à télécharger. Requis si `-d` n'est pas fourni (sauf avec `--from-dir`). |
| `-d`, `--digest DIGEST` | Digest exact à télécharger, avec ou sans préfixe `sha256:`. Peut être combiné avec `-t` : le digest précise le contenu exact, le tag crée en plus un pointeur local sur ce contenu. |
| `-o`, `--output ARCHIVE` | Chemin de l'archive à produire. **Si omis**, généré automatiquement : `IMAGE-LABEL-ARCH.tar.gz` (`LABEL` = tag, ou 12 premiers caractères du digest si pas de tag ; `/` de l'image remplacés par `-`). |
| `-k`, `--gpg-key KEY_ID` | Signe l'archive avec cette clé GPG (`gpg --detach-sign --armor`). Par défaut : pas de signature. |
| `--from-dir DIR` | Utilise un répertoire déjà produit par `skopeo copy ... dir:DIR` au lieu d'appeler skopeo — permet un usage 100% offline (téléchargez sur une machine connectée, transférez le répertoire, packagez ici). |
| `--source docker://...` | Préfixe de source skopeo. Défaut : `docker://`. |
| `--arch ARCH` | Architecture à télécharger (`amd64`, `arm64`, `arm`, `386`, `ppc64le`, `s390x`...). **Défaut : `amd64`** (une seule plateforme). `--arch all` récupère toutes les plateformes disponibles (manifest-list multi-arch). |
| `--os OS` | Système d'exploitation, utilisé avec `--arch` (hors `all`). Défaut : `linux`. |
| `--keep-workdir` | Conserve le répertoire de travail temporaire (debug). |
| `--with-signatures` | Recherche et embarque, en plus de l'image, les artefacts cosign associés : signature, attestation, SBOM legacy, et le repli statique OCI 1.1 "referrers". Voir [Signatures et SBOM (cosign)](#signatures-et-sbom-cosign). Nécessite `skopeo`. |
| `--sig-from-dir DIR` / `--att-from-dir DIR` / `--sbom-from-dir DIR` | Équivalents 100% offline, artefact par artefact : `DIR` est un répertoire `skopeo dir:` déjà produit pour le tag compagnon correspondant. |

**Exemples :**

```bash
registry-cli.sh pull -i alpine -t 3.20
#   -> alpine-3.20-amd64.tar.gz

registry-cli.sh pull -i alpine -t 3.20 -k 0xDEADBEEF
#   archive signée GPG

registry-cli.sh pull -i alpine -t 3.20 --arch arm64
#   -> alpine-3.20-arm64.tar.gz

registry-cli.sh pull -i alpine -t 3.20 --arch all
#   -> alpine-3.20-all.tar.gz (manifest-list complète)

registry-cli.sh pull -i alpine -d sha256:abcd1234...
#   -> alpine-abcd1234abcd-amd64.tar.gz (pas de pointeur de tag)

# Poste connecté : télécharge avec skopeo seul
skopeo copy --override-arch amd64 --override-os linux \
    docker://alpine:3.20 dir:/tmp/skopeo-alpine

# Poste air-gapped : transférez /tmp/skopeo-alpine, puis
registry-cli.sh pull -i alpine -t 3.20 --from-dir /tmp/skopeo-alpine

registry-cli.sh pull -i alpine -t 3.20 --with-signatures
#   embarque en plus la signature/attestation/SBOM cosign si présentes
```

### `upload` — placer une archive dans la registry

```
registry-cli.sh upload -a ARCHIVE -r REGISTRY_ROOT [options]
```

| Option | Description |
|---|---|
| `-a`, `--archive ARCHIVE` | **Obligatoire.** Archive `.tar.gz` produite par `pull`. |
| `-r`, `--registry-root DIR` | **Obligatoire.** Racine filesystem de la registry cible. |
| `--regen-config` / `--no-regen-config` | Régénère `v2/.htaccess`, `v2/error.json` et les `.htaccess` par image après l'ajout. **Activé par défaut.** |
| `--require-signature` | Échoue si l'archive n'a pas de signature `.asc` à côté d'elle. |
| `--skip-checksum` | Ne vérifie pas le fichier `.sha256` associé. |
| `--gpg-keyring FICHIER` | Trousseau de clés publiques (`gpg --export`) à importer temporairement pour la vérification, au lieu d'utiliser votre trousseau GPG personnel. |

**Vérifications effectuées, dans l'ordre :**
1. Checksum SHA256 de l'archive (si `ARCHIVE.sha256` existe, sauf `--skip-checksum`).
2. Signature GPG (si `ARCHIVE.asc` existe) — la vérification échoue et bloque l'upload si la signature est invalide. Si aucune signature n'est présente, l'upload continue sauf si `--require-signature` est donné.
3. Extraction, puis **fusion** (`rsync -a`, ou `cp -a` en repli) dans `REGISTRY_ROOT/v2/` — rien d'existant n'est écrasé ou supprimé.
4. Régénération de la configuration Apache (sauf `--no-regen-config`).

**Exemples :**

```bash
registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish

registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish \
    --require-signature --gpg-keyring ./trusted-keys.asc
```

### `list` — inventaire de la registry

```
registry-cli.sh list -r REGISTRY_ROOT [--json]
```

| Option | Description |
|---|---|
| `-r`, `--registry-root DIR` | **Obligatoire.** |
| `--json` | Sortie JSON au lieu d'un tableau texte. |

Affiche, pour chaque image/tag : image, tag, digest, présence
signature/attestation/SBOM cosign (colonne `COSIGN`, ex: `sig,att`), nombre
de blobs, **taille totale de l'image** (manifeste + tous les blobs qu'il
référence + artefacts cosign présents, PAS juste le petit fichier JSON du
manifeste), date de dernière modification. Les artefacts
cosign eux-mêmes — tags compagnons (`sha256-<digest>.sig`/`.att`/`.sbom`,
tag de repli `sha256-<digest>`), **et leurs éventuelles copies canoniques
`manifests/sha256:xxx`**, y compris pour chaque entrée référencée par le
repli "referrers" — ne sont **jamais** listés comme des images ou tags à
part : ils sont rattachés au vrai tag/image qu'ils concernent, déjà
signalés par la colonne `COSIGN`. En JSON, trois champs booléens
`signature`/`attestation`/`sbom` remplacent cette colonne.

```bash
registry-cli.sh list -r /srv/registrish
registry-cli.sh list -r /srv/registrish --json | jq '.[] | select(.signature) | .image'
```

### `remove` — supprimer un tag, un digest, ou une image

```
registry-cli.sh remove -r REGISTRY_ROOT --image IMAGE [--tag TAG | --digest DIGEST] [options]
```

| Option | Description |
|---|---|
| `-r`, `--registry-root DIR` | **Obligatoire.** |
| `--image IMAGE` | **Obligatoire.** |
| `--tag TAG` | Tag à supprimer. Mutuellement exclusif avec `--digest`. |
| `--digest DIGEST` | Digest exact à supprimer (`manifests/sha256:xxx`), avec ou sans préfixe `sha256:`. Mutuellement exclusif avec `--tag`. Si ce digest est encore référencé par un tag existant, un **avertissement** est affiché avant confirmation (le tag restera pullable par son nom, mais plus par ce digest précis). |
| *(ni `--tag` ni `--digest`)* | Supprime l'image **entière** (tous les tags, manifestes, blobs). |
| `--gc` / `--no-gc` | Nettoie les manifestes/blobs de l'image devenus orphelins après la suppression. Les blobs sont stockés par image : ce nettoyage n'affecte jamais les autres images. **Activé par défaut.** |
| `--purge-if-empty` / `--no-purge-if-empty` | S'il ne reste plus aucun tag après la suppression, supprime aussi le répertoire de l'image. **Activé par défaut.** |
| `-y`, `--yes` | Ne demande pas de confirmation. |
| `--dry-run` | Simule l'opération (GC compris) sans rien supprimer réellement. |
| `--regen-config` / `--no-regen-config` | Régénère la config Apache après suppression. **Activé par défaut.** |

**Exemples :**

```bash
# Supprimer un tag précis (gc + purge-if-empty appliqués automatiquement)
registry-cli.sh remove -r /srv/registrish --image alpine --tag 3.19

# Supprimer un digest précis
registry-cli.sh remove -r /srv/registrish --image alpine \
    --digest sha256:abcd1234...

# Supprimer une image entière
registry-cli.sh remove -r /srv/registrish --image library/nginx -y

# Prévisualiser sans rien supprimer
registry-cli.sh remove -r /srv/registrish --image alpine --tag 3.19 --dry-run

# Désactiver le nettoyage automatique (juste retirer le pointeur de tag)
registry-cli.sh remove -r /srv/registrish --image alpine --tag 3.19 \
    --no-gc --no-purge-if-empty
```

### `index` — page d'accueil HTML de la registry

```
registry-cli.sh index -r REGISTRY_ROOT
```

Génère `REGISTRY_ROOT/index.html` : un tableau de bord statique et
**entièrement autonome** (CSS/JS inline, aucune ressource externe, aucun
CDN), organisé **par image** plutôt qu'en table plate : chaque image est une
carte repliable regroupant tous ses tags, et à l'intérieur d'une carte, les
tags qui pointent vers un **contenu identique** (ex: `latest` et `3.21`
poussés sur le même digest) sont affichés sur une seule ligne au lieu
d'être dupliqués. Chaque ligne montre architecture(s), digest, badges
cosign, nombre de blobs, taille et date de modification.

Une barre de statistiques en tête (nombre d'images, de tags, d'images
signées/attestées, volume total) donne une vue d'ensemble immédiate.
Recherche et tri (nom, nombre de tags, taille, date) se font côté client en
JavaScript pur ; un bouton reploie/déplie toutes les cartes d'un coup, et
chaque carte individuellement au clic sur son en-tête. Cliquer sur un
digest, ou sur l'icône ⧉ à côté d'un tag, le copie dans le presse-papier
(`image:tag` pour un tag, le digest complet sinon).

L'architecture est détectée automatiquement :
- pour une **manifest-list** (multi-arch), depuis les champs
  `platform.architecture`/`platform.os` de chaque entrée ;
- pour un **manifeste simple**, en lisant le blob de configuration qu'il
  référence (`config.digest`), dont les champs `architecture`/`os`
  donnent la plateforme.

Cette page est **régénérée automatiquement** par `upload` et `remove` (sauf
`--no-regen-config`). La commande `index` sert à la régénérer isolément
(après une modification manuelle de la registry, ou pour l'ajouter à une
registry existante qui n'en a pas encore).

```bash
registry-cli.sh index -r /srv/registrish
# puis ouvrir /srv/registrish/index.html dans un navigateur,
# ou le servir via le même Apache2 que la registry elle-même.
```

La page affiche aussi des badges 🔏 signé / 📎 attesté / 📄 SBOM pour chaque
tag concerné.

### `verify` — vérifier une signature cosign

```
registry-cli.sh verify -u REGISTRY_URL -i IMAGE (-t TAG | -d DIGEST) -k CLE_PUBLIQUE [options] [-- ARGS_COSIGN...]
```

**Différence importante avec toutes les autres commandes** : `verify` (et
`sbom`) ne touchent **jamais** un chemin local. cosign parle le protocole
HTTP "OCI Distribution", donc `REGISTRY_URL` doit être l'hôte où `v2/` est
réellement **servi** (ex: `registry.example.com`, `localhost:8080`) — pas
`REGISTRY_ROOT`.

| Option | Description |
|---|---|
| `-u`, `--registry-url HOTE[:PORT]` | **Obligatoire.** Hôte de la registry servie en HTTP(S). |
| `-i`, `--image IMAGE` | **Obligatoire.** |
| `-t`, `--tag TAG` / `-d`, `--digest DIGEST` | Référence à vérifier (mutuellement exclusifs). |
| `-k`, `--key FICHIER` | **Obligatoire.** Clé publique cosign (`cosign.pub`). Seule la vérification **par clé** est supportée (pas de mode "keyless" Rekor/Fulcio, qui nécessiterait un accès réseau à la transparence Sigstore publique au moment de la vérification — incompatible avec l'usage 100% offline de cet outil). |
| `--no-expand` | Ne pas étendre `-i`/`--image` au format long. |
| `-- ARGS_COSIGN...` | Arguments cosign supplémentaires transmis tels quels (ex: options spécifiques à votre version de cosign pour un registre HTTP sans TLS). |

```bash
registry-cli.sh verify -u registry.example.com -i alpine -t 3.20 -k cosign.pub
```

### `sbom` — extraire un SBOM CycloneDX

```
registry-cli.sh sbom -u REGISTRY_URL -i IMAGE (-t TAG | -d DIGEST) [options] [-- ARGS_COSIGN...]
```

Extrait le SBOM (CycloneDX par défaut) attaché en tant qu'attestation
in-toto cosign, en JSON **brut** — le SBOM lui-même, pas l'enveloppe DSSE
qui le signe. Même remarque que `verify` : `REGISTRY_URL` cible la registry
servie en HTTP, pas un chemin local.

| Option | Description |
|---|---|
| `-u`, `--registry-url HOTE[:PORT]` | **Obligatoire.** |
| `-i`, `--image IMAGE` | **Obligatoire.** |
| `-t`, `--tag TAG` / `-d`, `--digest DIGEST` | Référence ciblée (mutuellement exclusifs). |
| `-k`, `--key FICHIER` | Si fournie, l'attestation est **vérifiée** (`cosign verify-attestation`) avant extraction. **Sans `-k`**, elle est seulement **téléchargée sans aucune vérification** (`cosign download attestation`) — à réserver à l'inspection, pas à un usage de confiance. |
| `--type TYPE` | Type de prédicat in-toto ciblé. Défaut : `cyclonedx`. |
| `-o`, `--output FICHIER` | Fichier de sortie. Défaut : stdout. |
| `--no-expand` | Ne pas étendre `-i`/`--image` au format long. |
| `-- ARGS_COSIGN...` | Arguments cosign supplémentaires transmis tels quels. |

En cas d'attestations multiples du même type pour une image, seule la
première est extraite.

```bash
registry-cli.sh sbom -u registry.example.com -i alpine -t 3.20 \
    -k cosign.pub -o alpine-3.20.cdx.json
```

## Signatures et SBOM (cosign)

`pull --with-signatures` (ou `--sig-from-dir`/`--att-from-dir`/`--sbom-from-dir`
pour un usage 100% offline) télécharge et conserve les artefacts
[cosign](https://github.com/sigstore/cosign) associés à une image — au même
titre que n'importe quel autre tag de la registry, puisque c'est exactement
ce qu'ils sont (voir [Concepts](#concepts)). `upload`, `list` et `index`
les portent déjà nativement : aucun changement de leur part n'était
nécessaire, seule leur énumération des tags a été ajustée pour ne pas les
afficher comme de faux tags d'image.

`verify` et `sbom`, en revanche, sont des commandes véritablement à part :
elles ne lisent **aucun fichier local**, elles parlent le protocole HTTP
"OCI Distribution" via `cosign`, donc elles ciblent l'URL où la registry est
**servie** (Apache2) — typiquement la même registry après un `upload`, mais
ça pourrait tout aussi bien être la registry source d'origine.

**Flux typique de bout en bout :**

```bash
# 1. Récupérer l'image + ses artefacts cosign (poste connecté)
registry-cli.sh pull -i alpine -t 3.20 --with-signatures -o alpine.tar.gz

# 2. Déployer (poste avec accès à la registry cible, éventuellement air-gapped)
registry-cli.sh upload -a alpine.tar.gz -r /srv/registrish

# 3. Vérifier après déploiement, contre la registry telle que servie
registry-cli.sh verify -u registry.example.com -i alpine -t 3.20 -k cosign.pub
registry-cli.sh sbom -u registry.example.com -i alpine -t 3.20 -k cosign.pub
```

## Format de l'archive

```
ARCHIVE.tar.gz
├── v2/<image>/manifests/sha256:<digest>   # manifeste canonique
├── v2/<image>/manifests/<tag>             # copie nommée par tag (si -t donné)
├── v2/<image>/blobs/sha256:<digest>       # config + layers
└── registrish-archive.json                # métadonnées : image, tag, digest,
                                            #   arch, created_at, tool, source
ARCHIVE.tar.gz.sha256                      # toujours généré
ARCHIVE.tar.gz.asc                         # si -k/--gpg-key fourni
```

## Structure de la registry produite

```
REGISTRY_ROOT/
├── index.html                    # tableau de bord (voir commande 'index')
└── v2/
    ├── .htaccess                # ErrorDocument 404 /v2/error.json
    ├── error.json                # réponse 404 standard registrish
    └── <image>/                  # ex: alpine, ou library/nginx (imbriqué)
        ├── manifests/
        │   ├── .htaccess          # ForceType + Docker-Content-Digest par fichier
        │   ├── <tag>               # copie du manifeste nommée par tag
        │   └── sha256:<digest>     # copie canonique nommée par digest
        └── blobs/
            └── sha256:<digest>     # config JSON + layers (pas de .htaccess)
```

## Servir la registry avec Apache2

Le protocole registry v2 a besoin que chaque manifeste soit servi avec le
bon `Content-Type` (schéma 1 vs schéma 2/OCI) et l'en-tête
`Docker-Content-Digest`. Comme il n'y a pas de serveur applicatif ici, ce
script s'appuie entièrement sur des fichiers `.htaccess` (`ForceType`,
`Header add`) déposés dans chaque répertoire `manifests/`.

**Pour que ces `.htaccess` soient pris en compte, Apache doit avoir
`AllowOverride All` (ou au moins `FileInfo`) sur le répertoire servi.**
Ce n'est **pas** le réglage par défaut de l'image officielle
`httpd:2.4` (son `httpd.conf` a `AllowOverride None`) : sans ce réglage,
Apache ignore silencieusement tous les `.htaccess` — aucun `Content-Type`
ni `Docker-Content-Digest` n'est envoyé, et `podman`/`docker pull` échoue
typiquement avec `unsupported schema version 2` (schéma 2 lu comme
schéma 1faute de `Content-Type`).

Pour tester rapidement avec l'image officielle telle quelle, ajoutez les
options `-c` qui activent `AllowOverride All` au démarrage, sans fichier
de config supplémentaire :

```bash
podman run -dit --name my-apache-app -p 8000:80 \
    -v "$PWD":/usr/local/apache2/htdocs/ \
    docker.io/library/httpd:2.4 \
    httpd-foreground \
    -c "<Directory /usr/local/apache2/htdocs>" \
    -c "AllowOverride All" \
    -c "</Directory>"
```

(remplacez `podman` par `docker` au besoin ; la syntaxe est identique).
Vérification rapide une fois le conteneur démarré :

```bash
curl -sI http://localhost:8000/v2/<image>/manifests/<tag>
# doit contenir Content-Type: application/vnd.oci.image.manifest.v1+json
# (ou +prettyjws pour du schéma 1) et Docker-Content-Digest: sha256:...
# Si ces deux en-têtes sont absents, .htaccess n'est pas honoré.
```

En production, préférez une image Apache dédiée (Dockerfile avec
`AllowOverride All` dans un vhost, ou config équivalente sur un Apache
"nu") plutôt que ces `-c` en ligne de commande.

## Workflows type

**Signature et vérification GPG de bout en bout :**

```bash
registry-cli.sh pull -i alpine -t 3.20 -k 0xDEADBEEF
registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish \
    --require-signature
```

**Air-gapped (aucun accès réseau sur la machine cible) :**

```bash
# Sur une machine connectée :
skopeo copy --override-arch amd64 --override-os linux \
    docker://alpine:3.20 dir:/tmp/skopeo-alpine
# -> transférer /tmp/skopeo-alpine sur la machine cible (clé USB, etc.)

# Sur la machine cible, sans réseau :
registry-cli.sh pull -i alpine -t 3.20 --from-dir /tmp/skopeo-alpine
registry-cli.sh upload -a alpine-3.20-fromdir.tar.gz -r /srv/registrish
```

**Cycle de vie complet d'une image :**

```bash
registry-cli.sh pull -i alpine -t 3.20
registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish
registry-cli.sh list -r /srv/registrish
registry-cli.sh remove -r /srv/registrish --image alpine --tag 3.19   # ancienne version
```

## Notes et limites connues

- **Fidélité à l'original** : la conversion skopeo → registry et la
  génération Apache sont des traductions bash fidèles du vrai code source
  de `dir2reg.sh` et `gen-apache2.sh` (fourni directement par l'auteur du
  projet), pas des suppositions.
- **Bug corrigé par rapport à l'original** : le `gen-apache2.sh` original
  utilise un glob `v2/*/manifests` qui ne descend que d'un niveau et rate
  silencieusement les images à namespace imbriqué (ex: `library/nginx`).
  Ce script utilise un `find` récursif à la place.
- **Non testé contre un vrai `skopeo`** : la logique de conversion a été
  validée avec des fixtures reproduisant fidèlement le format réel de
  `skopeo dir:` (vrais digests SHA256, conventions de nommage), mais pas
  contre une exécution réelle de skopeo (indisponible dans l'environnement
  de développement). Testez une première fois sur une image réelle avant
  un usage en production.
- **Backend Apache2 uniquement** : la génération de configuration ne
  couvre que Apache2 (`.htaccess` + `mod_headers`), pas NGINX/Netlify/S3.
- **Support cosign non testé contre un vrai `cosign`/`skopeo`** : ni l'un
  ni l'autre binaire n'était disponible dans l'environnement de
  développement (pas d'accès réseau pour les installer). La logique de
  détection/conservation des artefacts (`is_cosign_companion_tag`,
  `convert_skopeo_dir_to_v2` appliqué aux tags `.sig`/`.att`/`.sbom`/
  `sha256-<digest>`) et l'extraction JSON de `sbom` (décodage DSSE
  base64 → `predicate`) sont couvertes par des tests utilisant de faux
  binaires `skopeo`/`cosign` reproduisant fidèlement leur interface en
  ligne de commande — mais jamais vérifiées contre les vrais outils.
  Testez une première fois sur une image réellement signée avant un usage
  en production.
- **Convention cosign supposée** : `pull --with-signatures` suppose la
  convention "tag-based" historique (`sha256-<digest>.sig`/`.att`/`.sbom`)
  et le repli statique OCI 1.1 "referrers" (`sha256-<digest>`, avec
  récupération récursive d'un niveau des manifestes qu'il référence). Si
  votre registry source pousse les signatures autrement (API Referrers
  dynamique sans tag de repli, par exemple), elles ne seront pas trouvées.
  Vérifié en conditions réelles contre `registry.access.redhat.com` :
  cette registry a un tag `sha256-<digest>` qui n'a rien à voir avec la
  convention "referrers" (c'est un simple alias renvoyant le manifeste de
  l'image telle quelle) — le script détecte ce cas (même digest que
  l'image) et l'ignore, pour ne pas masquer l'image réelle dans
  `list`/`index`.
- **`verify`/`sbom` nécessitent un registre HTTP réellement accessible** :
  contrairement au reste de l'outil, ces deux commandes ne sont pas
  offline — `cosign` doit pouvoir joindre `REGISTRY_URL` en HTTP(S) au
  moment de l'appel. Un registre HTTP sans TLS peut nécessiter des options
  cosign spécifiques selon votre version (voir `-- ARGS_COSIGN...`).

## Tests

Une suite de tests unitaires et bout-en-bout est fournie dans `tests/`,
basée sur [Bats](https://github.com/bats-core/bats-core) (`bats-core`,
paquet `bats` sous Debian/Ubuntu).

```sh
sudo apt-get install bats   # si besoin
bats tests/
```

Elle couvre :
- les fonctions utilitaires (`normalize_digest`, `normalize_image_name`,
  `extract_referenced_digests`, `read_media_type`, `escape_json_string`) ;
- la conversion `skopeo dir:` → arborescence `v2/` (`convert_skopeo_dir_to_v2`),
  avec des fixtures reproduisant fidèlement le format réel de `skopeo dir:`
  (vrais digests SHA256, conventions `manifest.json`/`*.manifest.json`) ;
- la génération de la configuration Apache (`regen_apache2_config`),
  y compris le cas namespace imbriqué (`library/nginx`) et le `.htaccess`
  anti-`mod_deflate` des blobs ;
- la détection de plateforme et la génération de `index.html`
  (`get_manifest_platforms`, `regen_index_html`) ;
- les sous-commandes `pull`, `upload`, `list`, `remove` (dont le GC) et
  `index`, testées bout-en-bout via des appels réels au script
  (sans dépendre de `skopeo`, grâce à `--from-dir`) ;
- les artefacts cosign (`tests/cosign.bats`) : filtrage des tags compagnons
  et badges dans `list`/`index`, `pull --with-signatures`/`--*-from-dir`
  (avec un faux binaire `skopeo` reproduisant son interface en ligne de
  commande, y compris le repli "referrers" OCI 1.1), et `verify`/`sbom`
  (avec un faux binaire `cosign`, pour exercer le décodage réel de
  l'enveloppe DSSE par `jq` dans `sbom`).

Le script peut être `source`-é sans déclencher l'exécution d'une commande
(le point d'entrée est protégé par `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`),
ce qui permet de tester ses fonctions internes directement.
