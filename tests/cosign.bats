#!/usr/bin/env bats
# Tests des fonctionnalités cosign : artefacts de signature/attestation/SBOM
# conservés par 'pull', filtrage/badges dans 'list'/'index', et les
# sous-commandes 'verify'/'sbom'.

load 'test_helper'

# --- is_cosign_companion_tag ------------------------------------------------

@test "is_cosign_companion_tag: reconnaît .sig/.att/.sbom et le tag referrers nu" {
    load_registry_cli
    local d="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    is_cosign_companion_tag "sha256-${d}.sig"
    is_cosign_companion_tag "sha256-${d}.att"
    is_cosign_companion_tag "sha256-${d}.sbom"
    is_cosign_companion_tag "sha256-${d}"
}

@test "is_cosign_companion_tag: rejette un vrai tag d'image" {
    load_registry_cli
    ! is_cosign_companion_tag "3.20"
    ! is_cosign_companion_tag "latest"
    ! is_cosign_companion_tag "sha256-tropcourt.sig"
}

# --- add_cosign_artifact_from_dir (offline) --------------------------------

@test "add_cosign_artifact_from_dir: place l'artefact sous le tag compagnon donné" {
    load_registry_cli
    local sig_src="${BATS_TEST_TMPDIR}/sig-src"
    build_skopeo_dir "$sig_src" > /dev/null
    local v2="${BATS_TEST_TMPDIR}/v2"
    add_cosign_artifact_from_dir "$sig_src" "myimage" "sha256-abcd.sig" "$v2"
    [ -f "${v2}/myimage/manifests/sha256-abcd.sig" ]
}

@test "add_cosign_artifact_from_dir: erreur explicite si manifest.json absent" {
    load_registry_cli
    local empty="${BATS_TEST_TMPDIR}/empty-src"
    mkdir -p "$empty"
    run add_cosign_artifact_from_dir "$empty" "myimage" "sha256-abcd.sig" "${BATS_TEST_TMPDIR}/v2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest.json introuvable"* ]]
}

# --- pull --sig/--att/--sbom-from-dir (100% offline) -----------------------

@test "pull --sig-from-dir: embarque la signature sous sha256-<digest>.sig" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "img-src" > /dev/null
    build_skopeo_dir "sig-src" > /dev/null
    run "$REGISTRY_CLI" pull -i myimage -t 3.20 --from-dir img-src --sig-from-dir sig-src -o out.tar.gz --no-expand
    [ "$status" -eq 0 ]
    local digest_hex
    digest_hex="$(sha256sum img-src/manifest.json | cut -d' ' -f1)"
    tar -tzf out.tar.gz > listing.txt
    grep -q "^v2/myimage/manifests/sha256-${digest_hex}.sig\$" listing.txt
    [[ "$output" == *"sha256-${digest_hex}.sig"* ]]
}

@test "pull --att-from-dir et --sbom-from-dir: embarquent les deux, indépendamment" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "img-src" > /dev/null
    build_skopeo_dir "att-src" > /dev/null
    build_skopeo_dir "sbom-src" > /dev/null
    run "$REGISTRY_CLI" pull -i myimage -t 3.20 --from-dir img-src --att-from-dir att-src --sbom-from-dir sbom-src -o out.tar.gz --no-expand
    [ "$status" -eq 0 ]
    local digest_hex
    digest_hex="$(sha256sum img-src/manifest.json | cut -d' ' -f1)"
    tar -tzf out.tar.gz > listing.txt
    grep -q "^v2/myimage/manifests/sha256-${digest_hex}.att\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256-${digest_hex}.sbom\$" listing.txt
}

@test "pull sans --with-signatures ni --*-from-dir: aucun artefact cosign, comportement inchangé" {
    cd "$BATS_TEST_TMPDIR"
    build_skopeo_dir "img-src" > /dev/null
    run "$REGISTRY_CLI" pull -i myimage -t 3.20 --from-dir img-src -o out.tar.gz --no-expand
    [ "$status" -eq 0 ]
    [[ "$output" != *"cosign"* ]]
    tar -tzf out.tar.gz > listing.txt
    ! grep -q '\.sig$\|\.att$\|\.sbom$' listing.txt
}

# --- pull --with-signatures (réseau simulé via un faux skopeo) ------------

@test "pull --with-signatures: récupère sig trouvée, ignore att/sbom absents, suit le repli referrers OCI 1.1" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    build_skopeo_dir "main-src" > /dev/null
    build_skopeo_dir "sig-src" > /dev/null
    build_skopeo_dir "ref1-src" > /dev/null
    # Contenu distinct pour ref2 afin d'obtenir un digest de manifest différent.
    mkdir -p "ref2-src"
    printf '{"architecture":"arm64","os":"linux","config":{}}' > "ref2-src/cfgtmp"
    local cfg2_digest; cfg2_digest="$(sha256sum ref2-src/cfgtmp | cut -d' ' -f1)"
    mv "ref2-src/cfgtmp" "ref2-src/${cfg2_digest}"
    printf 'other-layer-content' > "ref2-src/layertmp"
    local layer2_digest; layer2_digest="$(sha256sum ref2-src/layertmp | cut -d' ' -f1)"
    mv "ref2-src/layertmp" "ref2-src/${layer2_digest}"
    printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"digest":"sha256:%s"},"layers":[{"digest":"sha256:%s"}]}' \
        "$cfg2_digest" "$layer2_digest" > "ref2-src/manifest.json"

    local digest_hex ref1_digest ref2_digest
    digest_hex="$(sha256sum main-src/manifest.json | cut -d' ' -f1)"
    ref1_digest="$(sha256sum ref1-src/manifest.json | cut -d' ' -f1)"
    ref2_digest="$(sha256sum ref2-src/manifest.json | cut -d' ' -f1)"

    mkdir -p index-src
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"sha256:%s"},{"digest":"sha256:%s"}]}' \
        "$ref1_digest" "$ref2_digest" > index-src/manifest.json

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    {
        printf ':3.20\t%s\n' "${BATS_TEST_TMPDIR}/main-src"
        printf '.sig\t%s\n' "${BATS_TEST_TMPDIR}/sig-src"
        printf '.att\tFAIL\n'
        printf '.sbom\tFAIL\n'
        printf ':sha256-%s\t%s\n' "$digest_hex" "${BATS_TEST_TMPDIR}/index-src"
        printf '@sha256:%s\t%s\n' "$ref1_digest" "${BATS_TEST_TMPDIR}/ref1-src"
        printf '@sha256:%s\t%s\n' "$ref2_digest" "${BATS_TEST_TMPDIR}/ref2-src"
    } > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        run "$REGISTRY_CLI" pull -i myimage -t 3.20 --with-signatures -o out.tar.gz --no-expand

    [ "$status" -eq 0 ]
    [[ "$output" == *"trouvé : sha256-${digest_hex}.sig"* ]]
    [[ "$output" == *"absent : sha256-${digest_hex}.att"* ]]
    [[ "$output" == *"absent : sha256-${digest_hex}.sbom"* ]]
    [[ "$output" == *"trouvé : index de referrers"* ]]

    tar -tzf out.tar.gz > listing.txt
    grep -q "^v2/myimage/manifests/3.20\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256-${digest_hex}.sig\$" listing.txt
    ! grep -q "\.att\$\|\.sbom\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256:${digest_hex}\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256:${ref1_digest}\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256:${ref2_digest}\$" listing.txt
    # Chaque entrée de l'index referrers reçoit aussi un tag compagnon nu
    # (sha256-<son-propre-digest>), reconnu par is_cosign_companion_tag --
    # sans ça, sa copie canonique réapparaîtrait comme une fausse image
    # "(sans tag)" dans 'list'/'index' (voir le test dédié plus bas).
    grep -q "^v2/myimage/manifests/sha256-${ref1_digest}\$" listing.txt
    grep -q "^v2/myimage/manifests/sha256-${ref2_digest}\$" listing.txt
}

@test "pull --with-signatures : un tag 'sha256-<digest>' qui n'est PAS un index de referrers (alias vers le même manifeste, cas réel registry.access.redhat.com) ne doit pas masquer l'image réelle" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    build_skopeo_dir "main-src" > /dev/null
    local digest_hex; digest_hex="$(sha256sum main-src/manifest.json | cut -d' ' -f1)"

    # Cas réel observé sur registry.access.redhat.com : le tag "sha256-<digest>"
    # existe mais n'est PAS un index de referrers OCI 1.1 -- c'est un simple
    # alias qui renvoie EXACTEMENT le même contenu que le manifeste de l'image
    # (donc le même digest que digest_hex), sans rapport avec cosign/SBOM.
    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    {
        printf '@sha256:%s\t%s\n' "$digest_hex" "${BATS_TEST_TMPDIR}/main-src"
        printf '.sig\tFAIL\n'
        printf '.att\tFAIL\n'
        printf '.sbom\tFAIL\n'
        printf ':sha256-%s\t%s\n' "$digest_hex" "${BATS_TEST_TMPDIR}/main-src"
    } > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        "$REGISTRY_CLI" pull -i myimage --digest "sha256:${digest_hex}" \
        --with-signatures -o out.tar.gz --no-expand >/dev/null

    local root="${BATS_TEST_TMPDIR}/registry"
    "$REGISTRY_CLI" upload -a out.tar.gz -r "$root" >/dev/null

    run "$REGISTRY_CLI" list -r "$root" --json
    [ "$status" -eq 0 ]
    local n
    n="$(echo "$output" | jq 'length')"
    # L'image réelle doit rester visible (pas 0 entrée : c'était le bug --
    # son digest, identique à celui de l'alias, la faisait classer comme
    # "compagnon cosign" et donc masquer entièrement).
    [ "$n" -eq 1 ]
    echo "$output" | jq -e --arg d "sha256:${digest_hex}" '.[0].digest == $d' >/dev/null
}

@test "pull --with-signatures sur un pull par digest seul : les artefacts cosign n'apparaissent jamais comme de fausses images dans list/index" {
    cd "$BATS_TEST_TMPDIR"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_skopeo "$fakebin"

    # Contenu distinct pour CHAQUE artefact (image, sig, att, sbom, deux
    # referrers) : reproduit un cas réel où ces manifestes n'ont jamais le
    # même contenu/digest que l'image elle-même (contrairement à un simple
    # réemploi de build_skopeo_dir, qui produit toujours un contenu fixe).
    make_variant_skopeo_dir() {
        local dest="$1" label="$2"
        mkdir -p "$dest"
        local cfg="{\"architecture\":\"amd64\",\"os\":\"linux\",\"variant\":\"${label}\"}"
        printf '%s' "$cfg" > "${dest}/cfgtmp"
        local cd; cd="$(sha256sum "${dest}/cfgtmp" | cut -d' ' -f1)"
        mv "${dest}/cfgtmp" "${dest}/${cd}"
        printf 'layer-%s' "$label" > "${dest}/layertmp"
        local ld; ld="$(sha256sum "${dest}/layertmp" | cut -d' ' -f1)"
        mv "${dest}/layertmp" "${dest}/${ld}"
        printf '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"digest":"sha256:%s"},"layers":[{"digest":"sha256:%s"}]}' \
            "$cd" "$ld" > "${dest}/manifest.json"
    }

    make_variant_skopeo_dir main-src main
    make_variant_skopeo_dir sig-src sig
    make_variant_skopeo_dir att-src att
    make_variant_skopeo_dir sbom-src sbom
    make_variant_skopeo_dir ref1-src ref1
    make_variant_skopeo_dir ref2-src ref2

    local digest_hex ref1_digest ref2_digest
    digest_hex="$(sha256sum main-src/manifest.json | cut -d' ' -f1)"
    ref1_digest="$(sha256sum ref1-src/manifest.json | cut -d' ' -f1)"
    ref2_digest="$(sha256sum ref2-src/manifest.json | cut -d' ' -f1)"

    mkdir -p index-src
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"sha256:%s"},{"digest":"sha256:%s"}]}' \
        "$ref1_digest" "$ref2_digest" > index-src/manifest.json

    local map="${BATS_TEST_TMPDIR}/skopeo-map.tsv"
    {
        printf '@sha256:%s\t%s\n' "$digest_hex" "${BATS_TEST_TMPDIR}/main-src"
        printf '.sig\t%s\n' "${BATS_TEST_TMPDIR}/sig-src"
        printf '.att\t%s\n' "${BATS_TEST_TMPDIR}/att-src"
        printf '.sbom\t%s\n' "${BATS_TEST_TMPDIR}/sbom-src"
        printf ':sha256-%s\t%s\n' "$digest_hex" "${BATS_TEST_TMPDIR}/index-src"
        printf '@sha256:%s\t%s\n' "$ref1_digest" "${BATS_TEST_TMPDIR}/ref1-src"
        printf '@sha256:%s\t%s\n' "$ref2_digest" "${BATS_TEST_TMPDIR}/ref2-src"
    } > "$map"

    PATH="${fakebin}:${PATH}" FAKE_SKOPEO_MAP="$map" \
        "$REGISTRY_CLI" pull -i myimage --digest "sha256:${digest_hex}" \
        --with-signatures -o out.tar.gz --no-expand >/dev/null

    local root="${BATS_TEST_TMPDIR}/registry"
    "$REGISTRY_CLI" upload -a out.tar.gz -r "$root" >/dev/null

    run "$REGISTRY_CLI" list -r "$root" --json
    [ "$status" -eq 0 ]
    # Une SEULE entrée : l'image elle-même (tag vide, digest-only pull),
    # pas une par artefact cosign (sig/att/sbom/index/referrers).
    local n
    n="$(echo "$output" | jq 'length')"
    [ "$n" -eq 1 ]
    echo "$output" | jq -e --arg d "sha256:${digest_hex}" \
        '.[0].digest == $d and .[0].signature == true and .[0].attestation == true and .[0].sbom == true' >/dev/null

    # Idem côté index.html : une seule entrée "tag" dans les données JSON embarquées.
    local tag_entries
    tag_entries="$(grep -o '"tag":"[^"]*"' "${root}/index.html" | wc -l | tr -d ' ')"
    [ "$tag_entries" -eq 1 ]
}

# --- list/index : filtrage des tags compagnons + badges signé/SBOM --------

setup_registry_with_cosign_artifacts() {
    ROOT="${BATS_TEST_TMPDIR}/registry"
    local skopeo_dir="${BATS_TEST_TMPDIR}/skopeo-src"
    build_skopeo_dir "$skopeo_dir" > /dev/null
    load_registry_cli
    convert_skopeo_dir_to_v2 "$skopeo_dir" "myimage" "3.20" "${ROOT}/v2"
    DIGEST_HEX="$(sha256sum "$skopeo_dir/manifest.json" | cut -d' ' -f1)"
    # Signature + attestation présentes, SBOM legacy absent.
    cp "${ROOT}/v2/myimage/manifests/3.20" "${ROOT}/v2/myimage/manifests/sha256-${DIGEST_HEX}.sig"
    cp "${ROOT}/v2/myimage/manifests/3.20" "${ROOT}/v2/myimage/manifests/sha256-${DIGEST_HEX}.att"
}

@test "list: n'affiche pas les tags compagnons cosign comme des tags à part" {
    setup_registry_with_cosign_artifacts
    run "$REGISTRY_CLI" list -r "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3.20"* ]]
    [[ "$output" != *"sha256-${DIGEST_HEX}.sig"* ]]
    [[ "$output" != *"sha256-${DIGEST_HEX}.att"* ]]
}

@test "list: la colonne COSIGN reflète sig+att présents, sbom absent" {
    setup_registry_with_cosign_artifacts
    run "$REGISTRY_CLI" list -r "$ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sig,att"* ]]
}

@test "list --json: expose signature/attestation/sbom comme booléens" {
    setup_registry_with_cosign_artifacts
    run "$REGISTRY_CLI" list -r "$ROOT" --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].signature == true and .[0].attestation == true and .[0].sbom == false' >/dev/null
}

@test "index: exclut les tags compagnons cosign des entrées JSON, garde le vrai tag avec ses badges" {
    setup_registry_with_cosign_artifacts
    regen_index_html "$ROOT"
    grep -q '"tag":"3.20"' "${ROOT}/index.html"
    grep -q '"signed":true' "${ROOT}/index.html"
    grep -q '"attested":true' "${ROOT}/index.html"
    grep -q '"sbom":false' "${ROOT}/index.html"
    ! grep -q "\"tag\":\"sha256-${DIGEST_HEX}.sig\"" "${ROOT}/index.html"
}

# --- verify ------------------------------------------------------------

@test "verify: -u/-i/-k manquants sont chacun une erreur explicite" {
    run "$REGISTRY_CLI" verify -i alpine -t 3.20 -k /nonexistent
    [ "$status" -ne 0 ]
    [[ "$output" == *"registry-url"* ]]

    run "$REGISTRY_CLI" verify -u registry.example.com -t 3.20 -k /nonexistent
    [ "$status" -ne 0 ]
    [[ "$output" == *"-i/--image"* ]]

    run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"-k/--key"* ]]
}

@test "verify: --tag et --digest sont mutuellement exclusifs" {
    echo fake > "${BATS_TEST_TMPDIR}/cosign.pub"
    run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20 -d sha256:00 -k "${BATS_TEST_TMPDIR}/cosign.pub"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutuellement exclusifs"* ]]
}

@test "verify: clé publique introuvable est une erreur" {
    run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20 -k /nonexistent/cosign.pub
    [ "$status" -ne 0 ]
    [[ "$output" == *"clé publique introuvable"* ]]
}

@test "verify: échoue proprement si cosign est absent" {
    command -v cosign >/dev/null 2>&1 && skip "cosign est installé dans cet environnement"
    echo fake > "${BATS_TEST_TMPDIR}/cosign.pub"
    run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20 -k "${BATS_TEST_TMPDIR}/cosign.pub"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cosign"* ]]
}

@test "verify: construit la référence hôte/image:tag et appelle cosign verify (faux binaire)" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_cosign "$fakebin"
    echo fake > "${BATS_TEST_TMPDIR}/cosign.pub"
    PATH="${fakebin}:${PATH}" run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20 --no-expand -k "${BATS_TEST_TMPDIR}/cosign.pub"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry.example.com/alpine:3.20"* ]]
}

@test "verify: --no-expand absent -> normalise l'image dans la référence" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_cosign "$fakebin"
    echo fake > "${BATS_TEST_TMPDIR}/cosign.pub"
    PATH="${fakebin}:${PATH}" run "$REGISTRY_CLI" verify -u registry.example.com -i alpine -t 3.20 -k "${BATS_TEST_TMPDIR}/cosign.pub"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry.example.com/docker.io/library/alpine:3.20"* ]]
}

# --- sbom ----------------------------------------------------------------

@test "sbom: -u/-i manquants sont des erreurs explicites" {
    run "$REGISTRY_CLI" sbom -i alpine -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"registry-url"* ]]

    run "$REGISTRY_CLI" sbom -u registry.example.com -t 3.20
    [ "$status" -ne 0 ]
    [[ "$output" == *"-i/--image"* ]]
}

@test "sbom: échoue proprement si jq est absent (même avec cosign présent)" {
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_cosign "$fakebin"
    run bash -c '
        command() { if [[ "$1" == "-v" && "$2" == "jq" ]]; then return 1; fi; builtin command "$@"; }
        export -f command
        PATH="'"$fakebin"':$PATH" "'"$REGISTRY_CLI"'" sbom -u registry.example.com -i alpine -t 3.20
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"jq"* ]]
}

@test "sbom sans -k: télécharge sans vérification et extrait le prédicat CycloneDX (faux cosign)" {
    command -v jq >/dev/null 2>&1 || skip "jq non installé dans cet environnement"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_cosign "$fakebin"
    local out="${BATS_TEST_TMPDIR}/nosbom.cdx.json"
    PATH="${fakebin}:${PATH}" run "$REGISTRY_CLI" sbom -u registry.example.com -i alpine -t 3.20 --no-expand -o "$out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SANS VÉRIFICATION"* ]]
    [ -f "$out" ]
    jq -e '.bomFormat == "CycloneDX"' "$out" >/dev/null
}

@test "sbom avec -k: vérifie l'attestation puis extrait le prédicat, écrit dans -o" {
    command -v jq >/dev/null 2>&1 || skip "jq non installé dans cet environnement"
    local fakebin="${BATS_TEST_TMPDIR}/fakebin"
    install_fake_cosign "$fakebin"
    echo fake > "${BATS_TEST_TMPDIR}/cosign.pub"
    local out="${BATS_TEST_TMPDIR}/sbom.cdx.json"
    PATH="${fakebin}:${PATH}" run "$REGISTRY_CLI" sbom -u registry.example.com -i alpine -t 3.20 --no-expand \
        -k "${BATS_TEST_TMPDIR}/cosign.pub" -o "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    jq -e '.bomFormat == "CycloneDX"' "$out" >/dev/null
}
