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
  - [mirror](#mirror--synchroniser-plusieurs-imagestags-en-place-skopeo-sync)
  - [upload](#upload--placer-une-archive-dans-la-registry)
  - [list](#list--inventaire-de-la-registry)
  - [remove](#remove--supprimer-un-tag-un-digest-ou-une-image)
  - [gc](#gc--nettoyer-toute-la-registry-manifestsblobs-orphelins)
  - [sign](#sign--signervérifier-les-manifests-dune-registry-avec-gpg)
  - [index](#index--page-daccueil-html-de-la-registry)
  - [verify](#verify--vérifier-une-signature-cosign)
  - [sbom](#sbom--extraire-un-sbom-cyclonedx)
  - [completion](#auto-complétion)
- [Signatures GPG par manifest](#signatures-gpg-par-manifest)
- [Transfert par rsync (pull --to-dir / upload --from-dir)](#transfert-par-rsync-pull---to-dir--upload---from-dir)
- [Signatures et SBOM (cosign)](#signatures-et-sbom-cosign)
- [Format de l'archive](#format-de-larchive)
- [Structure de la registry produite](#structure-de-la-registry-produite)
- [⚠️ Servir la registry avec Apache2](#servir-la-registry-avec-apache2)
- [Workflows type](#workflows-type)
- [Notes et limites connues](#notes-et-limites-connues)

## Dépendances

| Outil       | Requis pour                                              | Obligatoire ?                  |
|-------------|-----------------------------------------------------------|---------------------------------|
| `bash`      | tout                                                       | oui                              |
| `tar`, `sha256sum`, `grep`, `sed`, `find` | tout                                   | oui (présents sur tout Linux)   |
| `skopeo`    | `pull` sans `--from-dir`                                   | non si `--from-dir` utilisé     |
| `gpg`       | signer (`pull -k`, `sign -k`) ou vérifier des signatures de manifests (`upload`, `sign --check`) | non si pas de signature en jeu  |
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

### Paquet RPM (AlmaLinux 9 / 10)

Un `.spec` (`packaging/rpm/registry-cli.spec`) et une CI GitHub Actions
(`.github/workflows/rpm.yml`) construisent et testent un paquet `noarch`
sur AlmaLinux 9 et 10 à chaque push touchant le script, les pages man ou le
`.spec`. Dépendances fortes : `bash`, `rsync`, `jq`. Dépendances faibles
(`Recommends`, non bloquantes) : `skopeo`, `gnupg2`, `cosign` — nécessaires
seulement pour certaines fonctionnalités (voir la section DEPENDENCIES des
pages man). Le paquet installe le binaire sous `/usr/bin/registry-cli`, les
pages man anglaise et française, et la complétion bash.

Construction locale (sur une machine RPM, ou via un conteneur AlmaLinux) :

```bash
version="$(grep -oP 'REGISTRY_CLI_VERSION="\K[^"]+' registry-cli.sh)"
pkgdir="registry-cli-${version}"
mkdir -p "/tmp/src/${pkgdir}"
cp registry-cli.sh README.md LICENSE "/tmp/src/${pkgdir}/"
cp -r man "/tmp/src/${pkgdir}/"
tar -C /tmp/src -czf "/tmp/src/${pkgdir}.tar.gz" "${pkgdir}"
rpmdev-setuptree
cp "/tmp/src/${pkgdir}.tar.gz" ~/rpmbuild/SOURCES/
cp packaging/rpm/registry-cli.spec ~/rpmbuild/SPECS/
rpmbuild -bb ~/rpmbuild/SPECS/registry-cli.spec
```

### Pages de manuel

```bash
man man/registry-cli.1              # anglais
man man/fr/registry-cli.1           # français
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
  architecture, date). Toujours accompagnée d'un `.sha256`. Si `-k` est
  fourni, chaque manifest canonique qu'elle contient est signé
  individuellement (`v2/.../manifests/sha256:<hex>.asc`) — voir
  [Signatures GPG par manifest](#signatures-gpg-par-manifest).
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
registry-cli.sh pull -i IMAGE (-t TAG | -d DIGEST) [-o ARCHIVE.tar.gz | --to-dir DIR] [options]
registry-cli.sh pull -i IMAGE [-t TAG] [-d DIGEST] [-o ARCHIVE.tar.gz | --to-dir DIR] --from-dir DIR
registry-cli.sh pull -c CONFIG.yaml [-o ARCHIVE.tar.gz | --to-dir DIR] [options]
```

**Mode image unique** (`-i`) :

| Option | Description |
|---|---|
| `-i`, `--image IMAGE` | **Obligatoire.** Nom de l'image (ex: `alpine`, `library/nginx`). |
| `-t`, `--tag TAG` | Tag à télécharger. Requis si `-d` n'est pas fourni (sauf avec `--from-dir`). |
| `-d`, `--digest DIGEST` | Digest exact à télécharger, avec ou sans préfixe `sha256:`. Peut être combiné avec `-t` : le digest précise le contenu exact, le tag crée en plus un pointeur local sur ce contenu. |
| `-o`, `--output ARCHIVE` | Chemin de l'archive à produire. **Si omis** (et sans `--to-dir`), généré automatiquement : `IMAGE-LABEL-ARCH.tar.gz` (`LABEL` = tag, ou 12 premiers caractères du digest si pas de tag ; `/` de l'image remplacés par `-`). Incompatible avec `--to-dir`. |
| `--to-dir DIR` | Au lieu d'une archive, fusionne directement (fichiers en clair, additif, idempotent) dans `DIR/v2`. Pensé pour un transfert par `rsync` minimisant les fichiers transférés. Voir [Transfert par rsync](#transfert-par-rsync-pull---to-dir--upload---from-dir). Incompatible avec `-o`. |
| `-k`, `--gpg-key KEY_ID` | Signe chaque manifest **canonique** produit avec cette clé GPG (`gpg --detach-sign --armor`, un `.asc` par manifest, jamais re-signé si déjà signé). Voir [Signatures GPG par manifest](#signatures-gpg-par-manifest). Par défaut : pas de signature. |
| `--from-dir DIR` | Utilise un répertoire déjà produit par `skopeo copy ... dir:DIR` au lieu d'appeler skopeo — permet un usage 100% offline (téléchargez sur une machine connectée, transférez le répertoire, packagez ici). |
| `--source docker://...` | Préfixe de source skopeo. Défaut : `docker://`. |
| `--arch ARCH` | Architecture à télécharger (`amd64`, `arm64`, `arm`, `386`, `ppc64le`, `s390x`...). **Défaut : `amd64`** (une seule plateforme). `--arch all` récupère toutes les plateformes disponibles (manifest-list multi-arch). |
| `--os OS` | Système d'exploitation, utilisé avec `--arch` (hors `all`). Défaut : `linux`. |
| `--keep-workdir` | Conserve le répertoire de travail temporaire (debug). |
| `--with-signatures` | Recherche et embarque, en plus de l'image, les artefacts cosign associés : signature, attestation, SBOM legacy, et le repli statique OCI 1.1 "referrers". Voir [Signatures et SBOM (cosign)](#signatures-et-sbom-cosign). Nécessite `skopeo`. |
| `--sig-from-dir DIR` / `--att-from-dir DIR` / `--sbom-from-dir DIR` | Équivalents 100% offline, artefact par artefact : `DIR` est un répertoire `skopeo dir:` déjà produit pour le tag compagnon correspondant. |

**Mode multi-images/tags** (`-c`, incompatible avec `-i`/`-t`/`-d`/`--from-dir`) :

| Option | Description |
|---|---|
| `-c`, `--config FICHIER` | **Obligatoire** (dans ce mode). Même fichier YAML `skopeo sync --src yaml` que [`mirror`](#mirror--synchroniser-plusieurs-imagestags-en-place-skopeo-sync). Synchronise tous les tags qu'il liste et les empaquette **tous dans une seule archive**, ou les fusionne dans `--to-dir DIR` si donné — pratique pour préparer un transfert vers une machine air-gapped ou par `rsync`, à `upload`er là-bas ensuite. `-o`/`--to-dir`, `-k`, `--keep-workdir` et `--with-signatures` restent valables ; `--arch`/`--os`/`--source`/`--no-expand` sont ignorées (portées par le fichier de config). |
| `--keep-going` | Transmis à `skopeo sync --keep-going` : ne s'arrête pas si un des tags listés est introuvable/en échec. |

Nom d'archive **si `-o` est omis** en mode `-c` : `CONFIG-mirror.tar.gz` (basename du
fichier de config, extension retirée).

**Exemples :**

```bash
registry-cli.sh pull -i alpine -t 3.20
#   -> alpine-3.20-amd64.tar.gz

registry-cli.sh pull -i alpine -t 3.20 -k 0xDEADBEEF
#   chaque manifest canonique de l'archive est signé GPG individuellement

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

# Poste connecté : synchronise plusieurs images/tags (sync.yaml, même format
# que 'mirror') dans UNE SEULE archive
registry-cli.sh pull -c sync.yaml -o mirror.tar.gz
#   -> mirror.tar.gz contient tous les tags listés dans sync.yaml

# Poste air-gapped : transférez mirror.tar.gz, puis
registry-cli.sh upload -a mirror.tar.gz -r /srv/registrish
```

### `mirror` — synchroniser plusieurs images/tags en place (`skopeo sync`)

```
registry-cli.sh mirror -c CONFIG.yaml -r REGISTRY_ROOT [options]
```

Contrairement à `pull` (une archive par tag, à uploader ensuite), `mirror`
s'appuie sur [`skopeo sync`](https://github.com/containers/skopeo/blob/main/docs/skopeo-sync.1.md)
pour récupérer, en une seule commande, une sélection de tags issue de
plusieurs images/registres, et les fusionne directement (en place, de façon
additive et dédupliquée par digest — comme `upload`) dans une registry déjà
servie. Pensé pour être **rejoué périodiquement (cron)** afin de garder à
jour des tags mouvants comme `latest`, sans retélécharger ce qui n'a pas
changé.

| Option | Description |
|---|---|
| `-c`, `--config FICHIER` | **Obligatoire.** Fichier YAML au format `skopeo sync --src yaml` (voir exemple ci-dessous, ou `man skopeo-sync`). Transmis tel quel à skopeo, non interprété par le script. |
| `-r`, `--registry-root DIR` | **Obligatoire.** Racine de la registry à mettre à jour EN PLACE. |
| `--with-signatures` | Recherche aussi, pour chaque tag synchronisé, les artefacts cosign associés (signature/attestation/SBOM/referrers) — une seule fois par digest (plusieurs tags pointant sur le même contenu ne redéclenchent pas la recherche). Désactivé par défaut, comme pour `pull`. |
| `--keep-going` | Transmis à `skopeo sync --keep-going` : ne s'arrête pas si un tag listé est introuvable/en échec. |
| `--dry-run` | Transmis à `skopeo sync --dry-run` : n'écrit rien dans `REGISTRY_ROOT`, affiche seulement ce qui serait synchronisé. |
| `--regen-config` / `--no-regen-config` | Régénère `v2/.htaccess` + `index.html` après la fusion (défaut : activé). |
| `--keep-workdir` | Conserve le répertoire de travail temporaire (debug). |

**Format du fichier de config** (voir `man skopeo-sync` pour la référence
complète — regex de tags, contraintes semver, identifiants par registre...) :

```yaml
docker.io:
  images:
    library/alpine:
      - "3.20"
      - "latest"
quay.io:
  images:
    coreos/etcd:
      - latest
```

**Exemples :**

```bash
registry-cli.sh mirror -c sync.yaml -r /srv/registrish

registry-cli.sh mirror -c sync.yaml -r /srv/registrish --with-signatures

# Aperçu sans rien écrire :
registry-cli.sh mirror -c sync.yaml -r /srv/registrish --dry-run
```

**Exemple de crontab** pour garder `latest` à jour toutes les heures :

```cron
0 * * * *  /opt/registry-cli.sh mirror -c /etc/registrish/sync.yaml -r /srv/registrish >> /var/log/registrish-mirror.log 2>&1
```

### `upload` — placer une archive dans la registry

```
registry-cli.sh upload -a ARCHIVE -r REGISTRY_ROOT [options]
registry-cli.sh upload --from-dir DIR -r REGISTRY_ROOT [options]
```

Une des deux sources est obligatoire, mutuellement exclusives :

| Option | Description |
|---|---|
| `-a`, `--archive ARCHIVE` | Archive `.tar.gz` produite par `pull`. |
| `--from-dir DIR` | Répertoire déjà produit par `pull --to-dir DIR` (ou `mirror`), transféré tel quel (ex: `rsync`). Voir [Transfert par rsync](#transfert-par-rsync-pull---to-dir--upload---from-dir). |

| Option | Description |
|---|---|
| `-r`, `--registry-root DIR` | **Obligatoire.** Racine filesystem de la registry cible. |
| `--regen-config` / `--no-regen-config` | Régénère `v2/.htaccess`, `v2/error.json` et les `.htaccess` par image après l'ajout. **Activé par défaut.** |
| `--require-signature` | Échoue si la source (archive ou répertoire) ne contient aucun manifest signé (`.asc`). |
| `--skip-checksum` | Ne vérifie pas le fichier `.sha256` associé. Mode `-a` uniquement ; sans effet avec `--from-dir`. |
| `--gpg-keyring FICHIER` | Trousseau de clés publiques (`gpg --export`) à importer temporairement pour la vérification des manifests signés, au lieu d'utiliser votre trousseau GPG personnel. |

**Vérifications effectuées, dans l'ordre :**
1. Avec `-a` : checksum SHA256 de l'archive (si `ARCHIVE.sha256` existe, sauf `--skip-checksum`), puis extraction. Avec `--from-dir` : aucune (le répertoire est utilisé directement, en lecture seule).
2. Signature GPG de chaque manifest canonique signé (`.asc` trouvé à côté de lui) — la vérification échoue et bloque l'upload (rien n'est fusionné) si l'une d'elles est invalide. `--require-signature` exige qu'au moins un manifest signé soit présent.
3. **Fusion** (`rsync -a`, ou `cp -a` en repli) dans `REGISTRY_ROOT/v2/` — rien d'existant n'est écrasé ou supprimé.
4. Régénération de la configuration Apache (sauf `--no-regen-config`).

**Exemples :**

```bash
registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish

registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish \
    --require-signature --gpg-keyring ./trusted-keys.asc

registry-cli.sh upload --from-dir /var/lib/registry-incoming -r /srv/registrish \
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

### `gc` — nettoyer toute la registry (manifests/blobs orphelins)

```
registry-cli.sh gc -r REGISTRY_ROOT [options]
```

Comme `remove --gc`, mais sur **toute** la registry en une seule commande, sans
supprimer aucun tag : parcourt chaque image sous `v2/` et retire les
manifestes/blobs devenus orphelins (plus référencés par aucun tag). Rien de
ce qui reste atteignable depuis un tag — y compris les artefacts cosign
compagnons (`.sig`/`.att`/`.sbom`/repli referrers) — n'est jamais touché. Un
manifest signé (`.asc`, voir [`sign`](#sign--signervérifier-les-manifests-dune-registry-avec-gpg))
est traité comme faisant partie du manifest lui-même : conservé tant que le
manifest est atteignable, supprimé avec lui sinon. Pensé pour un usage
périodique (cron) de routine, ou après plusieurs `remove --no-gc`.

| Option | Description |
|---|---|
| `-r`, `--registry-root DIR` | **Obligatoire.** |
| `--purge-empty-images` / `--no-purge-empty-images` | Supprime aussi le répertoire des images qui ne contiennent plus aucun tag (situation inhabituelle, indique en général une manipulation manuelle de la registry). **Désactivé par défaut.** |
| `-y`, `--yes` | Ne demande pas de confirmation. |
| `--dry-run` | Simule le nettoyage sans rien supprimer réellement. |
| `--regen-config` / `--no-regen-config` | Régénère la config Apache après nettoyage. **Activé par défaut.** |

**Exemples :**

```bash
# Prévisualiser ce qui serait nettoyé
registry-cli.sh gc -r /srv/registrish --dry-run

# Nettoyer pour de vrai
registry-cli.sh gc -r /srv/registrish -y
```

**Exemple de crontab** pour un nettoyage hebdomadaire :

```cron
0 3 * * 0  /opt/registry-cli.sh gc -r /srv/registrish -y >> /var/log/registrish-gc.log 2>&1
```

### `sign` — signer/vérifier les manifests d'une registry avec GPG

```
registry-cli.sh sign -r REGISTRY_ROOT (-k KEY_ID | --check) [options]
```

Signe (ou vérifie) rétroactivement, avec GPG, chaque manifest **canonique**
d'une registry déjà en place — utile pour signer du contenu ajouté par
`mirror` (qui n'appelle pas GPG lui-même), après une rotation de clé, ou
pour un contrôle d'intégrité périodique. Voir [Signatures GPG par
manifest](#signatures-gpg-par-manifest) pour le principe général.

| Option | Description |
|---|---|
| `-r`, `--registry-root DIR` | **Obligatoire.** |
| `-k`, `--gpg-key KEY_ID` | Signe chaque manifest canonique non encore signé avec cette clé. |
| `--check` | Ne signe rien : vérifie les `.asc` déjà présents (échoue net si l'un d'eux est invalide). Incompatible avec `-k`. |
| `-i`, `--image IMAGE` | Limite l'opération à cette image (chemin sous `v2/`, ex : `library/alpine`). Répétable. Par défaut : toute la registry. |
| `--gpg-keyring FICHIER` | Trousseau de clés publiques pour `--check`, au lieu du trousseau GPG personnel. |
| `--force` | Re-signe même les manifests déjà signés (après rotation de clé). Sans effet avec `--check`. |
| `--dry-run` | Affiche ce qui serait signé/vérifié sans rien écrire. |
| `-y`, `--yes` | Ne demande pas de confirmation. |
| `--regen-config` / `--no-regen-config` | Régénère la config Apache après signature. **Activé par défaut.** |

**Exemples :**

```bash
# Signature initiale (idempotente : ne re-signe pas ce qui l'est déjà)
registry-cli.sh sign -r /srv/registrish -k 0xDEADBEEF -y

# Limité à une image
registry-cli.sh sign -r /srv/registrish -k 0xDEADBEEF -y -i library/alpine

# Contrôle d'intégrité périodique (CI/cron), avec le trousseau public de l'équipe
registry-cli.sh sign -r /srv/registrish --check --gpg-keyring team-pubkeys.asc

# Après rotation de clé : re-signe tout avec la nouvelle clé
registry-cli.sh sign -r /srv/registrish -k 0xNEWKEY --force -y
```

### `index` — page d'accueil HTML de la registry

```
registry-cli.sh index -r REGISTRY_ROOT
```

Génère `REGISTRY_ROOT/index.html` : un tableau de bord statique et
**entièrement autonome** (CSS/JS inline, aucune ressource externe, aucun
CDN), au design inspiré du container registry de GitLab, organisé
**par image** plutôt qu'en table plate : chaque image est une carte
repliable regroupant tous ses tags, et à l'intérieur d'une carte, les tags
qui pointent vers un **contenu identique** (ex: `latest` et `3.21` poussés
sur le même digest) sont affichés sur une seule ligne au lieu d'être
dupliqués. Chaque ligne (repliée par défaut, comme sur GitLab) montre
tag(s), architecture(s), badges cosign, taille et date de publication
relative (« Publié il y a X », date absolue en info-bulle) — le digest
n'apparaît pas à ce niveau ; cliquer sur la ligne déplie un panneau de
détail avec le digest complet du **manifeste** (bouton ⧉ dédié pour le
copier), son **media type**, le digest de la **config** (le blob
`config.json` référencé — absent pour une manifest-list/index, qui n'a pas
de config à son propre niveau), le nombre de blobs, et — quand présents —
des lignes explicites pour la **signature**, l'**attestation** et le
**SBOM** cosign (convention `sha256-<digest>.{sig,att,sbom}`).

La page s'adapte au thème clair/sombre du système, et un bouton 🌓 dans
l'en-tête permet de forcer l'un ou l'autre (mémorisé dans le navigateur).
Une ligne de statistiques en tête (📦 images, 🏷️ tags, 💾 volume total,
🔏 images avec cosign) donne une vue d'ensemble immédiate. Recherche et tri
(nom, nombre de tags, taille, date) se font côté client en JavaScript pur ;
un bouton reploie/déplie toutes les cartes d'un coup, et chaque carte
individuellement au clic sur son en-tête. Cliquer sur le bouton ⧉ à côté
d'un digest, ou sur l'icône ⧉ à côté d'un tag, le copie dans le
presse-papier — préfixé par l'hôte:port qui sert effectivement la page
(ex. `localhost:8000/alpine:3.20`, ou `localhost:8000/ubi10@sha256:...`
pour une image sans tag), donc directement utilisable avec
`podman`/`docker pull`.

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

## Signatures GPG par manifest

`pull -k KEY_ID` et [`sign -k`](#sign--signervérifier-les-manifests-dune-registry-avec-gpg)
signent GPG chaque manifest **canonique** individuellement
(`v2/<image>/manifests/sha256:<hex>.asc`, détaché, armored) — jamais
l'archive dans son ensemble, jamais un tag (pointeur mutable), jamais un
blob (déjà content-addressed, donc son intégrité découle de celle du
manifest qui le référence par digest). C'est le même principe que les
signatures cosign (voir plus bas) : signer par digest de contenu, pas par
nom.

**Pourquoi pas signer l'archive entière ?** Une archive régénérée à
l'identique produit malgré tout un `.tar.gz` différent d'un run à l'autre
(métadonnées tar, ordre, horodatages), donc une signature d'archive globale
invalide systématiquement tout le paquet au moindre changement — y compris
quand la quasi-totalité du contenu (les blobs, souvent l'essentiel du poids)
est strictement inchangée. En signant au grain du manifest et en la
stockant à demeure dans `v2/`, seul le delta réel (un manifest modifié + son
`.asc`, tous deux petits) a besoin d'être re-transféré — un `rsync -a` d'une
arborescence `v2/` déjà signée vers un miroir ne retransfère jamais les
blobs ni les manifests inchangés.

`upload` vérifie automatiquement chaque manifest signé trouvé dans une
archive avant de le fusionner (voir [`upload`](#upload--placer-une-archive-dans-la-registry)) ;
`gc` et `remove --gc` traitent un `.asc` comme partie intégrante de son
manifest (jamais supprimé isolément, jamais laissé orphelin) ; `sign --check`
permet un contrôle d'intégrité périodique indépendant de tout déploiement.

**Bonnes pratiques :**
- Utilisez une **sous-clé de signature dédiée** pour l'automatisation
  (`gpg --quick-add-key`), pas la clé maître — une sous-clé se révoque et se
  fait tourner sans invalider votre identité GPG.
- Pour un usage non interactif, préférez une clé sans passphrase dans un
  `GNUPGHOME` dédié à l'automatisation, ou un `gpg-agent` déjà déverrouillé ;
  le script appelle `gpg --batch --yes` et ne gère pas d'invite de
  passphrase lui-même.
- Après une rotation de clé, `sign -k NOUVELLE_CLE --force` re-signe tout ;
  les anciennes signatures `.asc` sont simplement écrasées (elles ne sont
  pas conservées en plus).

**Point de migration :** les archives produites par une version antérieure
de `registry-cli.sh` étaient signées au niveau de l'archive entière
(`ARCHIVE.tar.gz.asc`). Ce fichier n'est plus reconnu ni vérifié par
`upload` — les archives déjà signées doivent être re-`pull`ées pour obtenir
des manifests signés individuellement.

## Transfert par rsync (`pull --to-dir` / `upload --from-dir`)

Scénario cible : une machine A a accès réseau et exécute `pull` (une image ou
plusieurs via `-c`) périodiquement (cron) ; une machine B, qui n'a **aucun**
accès réseau sortant, sert la registry aux clients internes. Le transfert
entre les deux se fait par `rsync` (SSH), et doit rester **minimal** : ne
retransférer que ce qui a réellement changé, jamais relire/rechiffrer des
blobs déjà présents côté B.

Le mode archive (`pull -o ARCHIVE.tar.gz`) ne convient **pas** à ce scénario :
un `.tar.gz` change intégralement d'un run à l'autre (horodatages tar, ordre
des entrées, ré-compression gzip), même si son contenu logique n'a pas
bougé — `rsync` de l'archive retransfère donc quasiment tout, à chaque fois,
quel que soit le delta réel.

`--to-dir`/`--from-dir` résolvent ça en gardant l'échange **en fichiers
individuels, content-addressed**, exactement comme le reste de la registry :

1. **Machine A**, périodiquement (cron) :
   ```bash
   registry-cli.sh pull -c sync.yaml --to-dir /var/lib/registry-staging -k 0xDEADBEEF -y
   ```
   `--to-dir` fusionne le résultat directement dans `/var/lib/registry-staging/v2`
   (fichiers en clair, pas d'archive), de façon **additive et idempotente** :
   un tag/blob déjà présent n'est jamais réécrit, et un manifest déjà signé
   n'est **jamais re-signé** (une signature GPG n'est pas déterministe —
   la re-signer produirait un `.asc` different à chaque run, et donc un
   nouveau transfert inutile). `/var/lib/registry-staging` n'est **pas** une
   registry servable (pas de `.htaccess`/`index.html` générés) : c'est un
   point de staging pur, à transférer.

2. **Transfert A → B**, périodiquement (cron, juste après le `pull`) :
   ```bash
   rsync -a --delete /var/lib/registry-staging/ machine-b:/var/lib/registry-incoming/
   ```
   Comme le contenu est content-addressed et stable d'un run à l'autre, seuls
   les fichiers réellement nouveaux ou modifiés sont transférés — les blobs
   (souvent l'essentiel du volume) et les manifests déjà signés ne bougent
   pas. `--delete` est optionnel : à activer si la machine A elle-même
   nettoie régulièrement `/var/lib/registry-staging` (ex: via `gc`) et que
   ce nettoyage doit se répercuter côté B.

3. **Machine B**, après chaque transfert :
   ```bash
   registry-cli.sh upload --from-dir /var/lib/registry-incoming -r /srv/registrish \
       --require-signature --gpg-keyring team-pubkeys.asc
   ```
   Vérifie la signature GPG de chaque manifest présent (abandonne sans rien
   fusionner si l'une est invalide — voir [`upload`](#upload--placer-une-archive-dans-la-registry)),
   puis fusionne dans `REGISTRY_ROOT/v2` exactement comme pour une archive.
   `/var/lib/registry-incoming` n'est jamais modifié par `upload` (lecture
   seule).

**Bonnes pratiques pour ce flux :**
- Toujours `-k` côté A et `--require-signature --gpg-keyring` côté B : sans
  ça, `rsync`/SSH garantit l'intégrité du *transport* mais rien ne garantit
  que le contenu déposé dans `/var/lib/registry-staging` sur A est légitime
  (ni ne détecte une modification faite directement sur B avant l'`upload`).
  La signature GPG par manifest est ce qui apporte la garantie de bout en
  bout, indépendamment du transport.
- `rsync` via SSH (`machine-b:...`) apporte confidentialité et intégrité du
  transport lui-même ; la signature GPG reste nécessaire en plus, car elle
  couvre aussi l'intégrité du **contenu** (avant/après le transport, pas
  seulement pendant).
- Limitez les droits du compte SSH utilisé pour le `rsync` à
  `/var/lib/registry-incoming` uniquement (ex: `rrsync`, ou une clé SSH avec
  `command=` restreint dans `authorized_keys`) — B n'a besoin de rien
  d'autre depuis A.

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
├── v2/<image>/manifests/sha256:<digest>       # manifeste canonique
├── v2/<image>/manifests/sha256:<digest>.asc   # sa signature GPG, si -k/--gpg-key fourni
├── v2/<image>/manifests/<tag>                 # copie nommée par tag (si -t donné)
├── v2/<image>/blobs/sha256:<digest>           # config + layers
└── registrish-archive.json                    # métadonnées : image, tag, digest,
                                                #   arch, created_at, tool, source
ARCHIVE.tar.gz.sha256                          # toujours généré
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
        │   ├── sha256:<digest>     # copie canonique nommée par digest
        │   └── sha256:<digest>.asc # sa signature GPG (si signé, voir 'sign'/'pull -k')
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

### `mod_mime_magic` (courant sur RHEL/CentOS) : une limite que `.htaccess` ne peut pas lever

Même avec `AllowOverride All` correctement actif, un blob peut encore être
livré avec un `Content-Encoding` fantaisiste (ex : `x-gzip`, un alias non
standard que ni Go — utilisé par podman/skopeo/docker — ni leur propre
détection de compression ne reconnaissent). Résultat côté client :
`podman --log-level debug pull` affiche `No compression detected` /
`Using original blob without modification`, puis échoue avec `Digest did
not match`, alors que le fichier sur disque est parfaitement intact
(vérifiable avec `curl` : voir plus bas).

**Cause** : nos fichiers de blobs n'ont pas d'extension. Si `mod_mime_magic`
est chargé côté serveur (activé par défaut sur certaines distributions,
notamment RHEL/CentOS — moins souvent sur Debian/Ubuntu ou l'image `httpd`
officielle), il *renifle* le contenu de ces fichiers et leur attribue lui
-même un `Content-Type`/`Content-Encoding` mal aligné avec ce que les
clients registry attendent. C'est une **limite structurelle** de cette
approche "que des fichiers statiques + `.htaccess`" : `mod_mime_magic`
fixe le `Content-Encoding` via un mécanisme interne à Apache que **aucune
directive de `.htaccess` ne peut retirer** (`Header unset`/`Header always
unset Content-Encoding` inclus — vérifié). Seule une modification de la
configuration serveur/`VirtualHost` fonctionne :

```apache
<VirtualHost *:8000>
    DocumentRoot /srv/registrish
    MIMEMagicFile none
    ...
</VirtualHost>
```

(ou, plus radicalement, ne pas charger le module du tout —
`LoadModule mime_magic_module modules/mod_mime_magic.so` en commentaire).

Diagnostic pour confirmer que c'est bien ce cas précis :

```bash
curl -sI http://localhost:8000/v2/<image>/blobs/sha256:<digest>
# Content-Encoding présent (ex: x-gzip) → c'est ce problème.

curl -s http://localhost:8000/v2/<image>/blobs/sha256:<digest> | sha256sum
sha256sum /chemin/vers/la/registry/v2/<image>/blobs/sha256:<digest>
# Les deux correspondent → le fichier sur disque n'est PAS en cause,
# seule l'étiquette HTTP ment.
```

## Workflows type

**Signature et vérification GPG de bout en bout :**

```bash
# Chaque manifest canonique de l'archive est signé individuellement
registry-cli.sh pull -i alpine -t 3.20 -k 0xDEADBEEF

# upload vérifie les manifests signés trouvés, refuse la fusion s'il n'y en a aucun
registry-cli.sh upload -a alpine-3.20-amd64.tar.gz -r /srv/registrish \
    --require-signature --gpg-keyring team-pubkeys.asc

# Contrôle d'intégrité périodique, indépendant de tout déploiement
registry-cli.sh sign -r /srv/registrish --check --gpg-keyring team-pubkeys.asc

# Signer rétroactivement du contenu déjà présent (ex: ajouté par 'mirror')
registry-cli.sh sign -r /srv/registrish -k 0xDEADBEEF -y
```

**Synchronisation périodique par rsync entre une machine de pull et une machine de service (transfert minimal, signé) :**

```bash
# Machine A (accès réseau), en cron, ex. toutes les heures :
registry-cli.sh pull -c sync.yaml --to-dir /var/lib/registry-staging -k 0xDEADBEEF -y
rsync -a /var/lib/registry-staging/ machine-b:/var/lib/registry-incoming/

# Machine B (pas d'accès réseau sortant), en cron, juste après :
registry-cli.sh upload --from-dir /var/lib/registry-incoming -r /srv/registrish \
    --require-signature --gpg-keyring team-pubkeys.asc
```

Voir [Transfert par rsync](#transfert-par-rsync-pull---to-dir--upload---from-dir)
pour le détail (pourquoi pas une archive, bonnes pratiques de bout en bout).

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
