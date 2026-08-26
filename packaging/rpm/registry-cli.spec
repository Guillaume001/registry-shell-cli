Name:           registry-cli
Version:        1.1.0
Release:        1%{?dist}
Summary:        Self-contained CLI to manage a static "registrish" Docker/OCI registry

License:        GPLv3+
URL:            https://github.com/Guillaume001/registry-shell-cli
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  bash

Requires:       bash
Requires:       rsync
Requires:       jq

# Feature-gated, not required for every subcommand:
#   skopeo  - 'pull'/'mirror' network operations (not needed with --from-dir)
#   gnupg2  - archive signing/verification ('pull -k' / 'upload')
#   cosign  - 'verify' and 'sbom'
Recommends:     skopeo
Recommends:     gnupg2
Recommends:     cosign

%description
registry-cli is a single, fully self-contained (offline-capable) Bash
script that manages a static Docker/OCI registry in the "registrish"
layout: a plain v2/<image>/{blobs,manifests} directory tree that can be
served by any static file host (Apache2, NGINX, Netlify, S3...).

It can package one or several images/tags into a portable, optionally
GPG-signed .tar.gz archive (pull), place that archive into a registry
(upload), synchronize a whole selection of images/tags directly into a
live registry (mirror), inventory it (list), remove tags/images and clean
up orphaned content (remove, gc), regenerate its HTML dashboard (index),
and verify cosign signatures or extract CycloneDX SBOMs (verify, sbom).

%prep
%autosetup -n %{name}-%{version}

%build
bash %{name}.sh completion > %{name}.bash-completion

%install
install -Dm0755 %{name}.sh %{buildroot}%{_bindir}/%{name}
install -Dm0644 man/registry-cli.1 %{buildroot}%{_mandir}/man1/%{name}.1
install -Dm0644 man/fr/registry-cli.1 %{buildroot}%{_mandir}/fr/man1/%{name}.1
install -Dm0644 %{name}.bash-completion %{buildroot}%{_datadir}/bash-completion/completions/%{name}

%check
bash -n %{name}.sh
./%{name}.sh --version
./%{name}.sh --help >/dev/null
for cmd in pull mirror upload list remove gc sign index verify sbom completion; do
    ./%{name}.sh "$cmd" --help >/dev/null
done

%files
%license LICENSE
%doc README.md
%{_bindir}/%{name}
%{_mandir}/man1/%{name}.1*
%{_mandir}/fr/man1/%{name}.1*
%{_datadir}/bash-completion/completions/%{name}

%changelog
* Wed Aug 26 2026 Guillaume COURS <15053338+Guillaume001@users.noreply.github.com> - 1.1.0-1
- Signature GPG par manifest (pull -k, nouvelle commande sign) au lieu de
  l'archive entière ; upload vérifie les manifests signés.
- pull --to-dir / upload --from-dir : transfert par rsync sans archive,
  additif et idempotent, pour minimiser les fichiers transférés.
- Correction : échec de signature GPG désormais détecté et bloquant
  (auparavant silencieusement ignoré) ; message d'erreur propre au lieu
  d'un crash "variable sans liaison" quand une option attend une valeur.

* Tue Aug 25 2026 Guillaume COURS <15053338+Guillaume001@users.noreply.github.com> - 1.0.0-1
- Initial RPM packaging for AlmaLinux 9/10.
