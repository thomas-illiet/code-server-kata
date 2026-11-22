# Stockage : mesures et profil optimisé

## Décision

Le profil conserve deux classes de données distinctes :

- `/home/podman` reste le PVC persistant pour le workspace, les extensions, la configuration et les données utilisateur code-server ;
- `/tmp` reste le tmpfs éphémère pour le graphroot Podman, les fichiers temporaires et les caches à forte rotation.

Le déploiement dirige vers `/tmp` `XDG_CACHE_HOME`, `TMPDIR`, le cache npm, le cache pip et `GOCACHE`. Podman conserve `graphroot=/tmp/podman-storage` et son OverlayFS rootless natif. Déplacer ce graphroot vers le PVC virtiofs rendrait les opérations de métadonnées beaucoup plus lentes et ne correspond pas au profil OverlayFS validé.

## Mesures live du 21 novembre 2026

Le microbenchmark a été exécuté dans le pod Kata courant, puis directement sur le chemin du PVC depuis le nœud. Les valeurs sont des médianes ; le débit séquentiel bénéficie des caches et ne représente donc pas à lui seul le média physique.

| Chemin | Backend observé | Écriture 128 Mio | Création de 1 000 fichiers |
|---|---|---:|---:|
| `/tmp` | tmpfs invité | 3 566 Mio/s | 11,5 ms |
| `/var/tmp` | `emptyDir` disque via virtiofs | 858 Mio/s | 462 ms |
| `/home/podman/workspace` | PVC `local-path` via virtiofs | 1 053 Mio/s | 452 ms |
| chemin du PVC sur le nœud | ext4 direct | 2 388 Mio/s | 11,8 ms |

La création de petits fichiers sur le PVC vu depuis l'invité est environ 38 fois plus lente que sur son ext4 vu directement depuis le nœud. La traversée virtiofs, et particulièrement ses métadonnées, est donc le goulot principal pour Git, npm, les arbres de build et les extractions de couches.

## Limites à surveiller

- Le cache Podman et les caches outils disparaissent lors du remplacement du pod.
- Le tmpfs est facturé à la mémoire du workload. Le pod dispose d'environ 9,8 Gio dans l'invité et `/tmp` y apparaît à environ 4,9 Gio, même si le manifeste déclare `sizeLimit: 8Gi`.
- Le PVC `local-path` demandé à 30 Gio est un répertoire du filesystem racine du nœud, pas un quota bloc de 30 Gio. Il faut surveiller l'espace réel de `/var/lib/rancher/k3s/storage`.
- Le PVC est local au nœud et ne constitue ni une sauvegarde ni une réplication.

## Évolution pour un stockage persistant plus rapide

Le prochain saut de performance ne vient pas d'un réglage du PVC `local-path` actuel. Il exige un volume bloc dédié présenté à Kata par un CSI bloc/LVM, idéalement sur un disque virtuel distinct du disque système K3s. Le format ext4 ou XFS est alors monté par l'infrastructure dans l'invité, sans ajouter `SYS_ADMIN` au conteneur.

Avant ce changement, utiliser une RuntimeClass de test et comparer au profil courant : I/O 4K aléatoires, débit séquentiel, créations/suppressions de petits fichiers, Git/npm et un build Podman réel. Un `emptyDir` Kata `block-plain` peut servir de scratch disque éphémère, mais sa capacité n'est pas dimensionnée par `emptyDir.sizeLimit` dans Kata 4.4 ; il ne doit pas être activé sur le profil principal sans filesystem hôte dédié et benchmark A/B.
