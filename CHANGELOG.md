# Journal des changements

Les changements notables de ce projet sont consignés dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) et les versions publiées suivent [Semantic Versioning](https://semver.org/lang/fr/). Les mesures datées et les résultats propres à une machine restent dans `docs/` plutôt que dans ce journal.

## Unreleased

### Added

- Image Ubuntu construite manuellement avec code-server et Podman rootless dans un unique conteneur.
- Exécution sous Kata Containers avec racine en lecture seule et PVC pour le home.
- Helpers `newuidmap` et `newgidmap` reconstruits depuis Shadow avec support libcap.
- Politique d’admission limitant le pod à `SETUID|SETGID` et interdisant les échappements hôte.
- Parcours principal WSL pour provisionner, déployer, vérifier et benchmarker l’environnement.
- Graphroot Podman et caches à forte rotation placés sur tmpfs.
- Documentation de production, procédure de montée de version et politique de sécurité publique.
- Overlay de production à image immuable, Service interne, Ingress TLS et NetworkPolicy.
- Validation CI Linux et Windows, avec reconstruction complète de l’image sans accès à un cluster.
- Contrôles locaux de publication pour les pins, secrets, chemins personnels et artefacts générés.

### Security

- Vérification des digests et checksums des principales sources téléchargées.
- Vérifications live du noyau invité, du mapping multi-UID, des capabilities et de l’allowlist setuid.
