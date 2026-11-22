# Architecture, sécurité et performance

## Objectif et frontière de confiance

Le code édité dans code-server et les images lancées par Podman sont considérés comme non fiables. La frontière principale face au nœud Kubernetes est la micro-VM Kata. La frontière secondaire est Podman rootless : le `root` d'un conteneur intérieur est mappé sur l'UID 1000 puis sur la plage subuid de cet utilisateur dans l'invité.

Le poste Windows, l'administrateur Kubernetes, la VM Multipass, l'image du workspace et l'installation Kata restent dans la base de confiance. Un administrateur Windows ou Kubernetes conserve nécessairement le contrôle du workload.

## Chemin d'exécution réellement utilisé

Le cluster est un K3s mono-nœud dans une VM Ubuntu 24.04 Multipass sur Hyper-V. La virtualisation imbriquée expose KVM à Kata. K3s lance le pod avec `runtimeClassName: kata-qemu-runtime-rs` et containerd crée une micro-VM dédiée.

Le workload contient exactement un conteneur Ubuntu 24.04 :

- code-server est le processus principal ;
- le binaire Podman est invoqué directement depuis son terminal ;
- Podman est daemonless, donc aucun sidecar ou socket distant n'est requis ;
- les deux utilisent l'UID/GID 1000 dès le premier processus.

L'image est construite à partir d'Ubuntu épinglé par digest. Les paquets Podman, Buildah, `uidmap`, Netavark, `passt`, `tini` et les outils utilisateur sont installés manuellement par APT. Les binaires `newuidmap/newgidmap` du paquet sont ensuite remplacés par un build multi-stage de Shadow 4.13 compilé avec `HAVE_SYS_CAPABILITY_H=1`; l'archive amont et son SHA-256 sont épinglés. code-server est lui aussi téléchargé dans une version épinglée et vérifié par SHA-256. `sudo` n'est pas installé.

## Rootless et capabilities minimales

Le conteneur Kubernetes est explicitement `privileged: false`. Son profil commence par `capabilities.drop: [ALL]` puis ajoute uniquement `SETGID` et `SETUID`. Ces deux bits restent dans le bounding set pour les helpers de mapping ; ils ne sont pas effectifs pour code-server :

- `runAsNonRoot: true` ;
- `runAsUser: 1000` et `runAsGroup: 1000` ;
- `supplementalGroupsPolicy: Strict`, avec le groupe effectif unique `1000` ;
- aucun init container ni conteneur éphémère ;
- `CapInh=CapPrm=CapEff=CapAmb=0` et `CapBnd=00000000000000c0` pour le processus principal ;
- seuls `/usr/bin/newuidmap` et `/usr/bin/newgidmap` conservent un bit setuid, tous les autres fichiers setid étant neutralisés ;
- Podman `rootless=true` ;
- un mapping `0 → 1000`, puis `1 → 100000` sur 65 536 UID/GID.

`allowPrivilegeEscalation` reste à `true`, donc `NoNewPrivs=0`, faute de quoi le noyau neutraliserait le bit setuid des helpers. Le build capability-aware de Shadow abandonne l'EUID root au profit de l'UID réel 1000 tout en conservant temporairement seulement `CAP_SETUID` ou `CAP_SETGID`. Le propriétaire du user namespace peut alors écrire le mapping sans `DAC_OVERRIDE` ni `SYS_ADMIN` dans l'enveloppe Kubernetes.

La matrice live a distingué trois cas :

1. zéro capability fonctionne seulement avec un mapping mono-UID et `ignore_chown_errors`; un build `USER 2000` échoue avec `setresgid: Invalid argument` ;
2. les helpers Ubuntu stock exigent quatre bits sur cette pile (`DAC_OVERRIDE`, `SETGID`, `SETUID`, `SYS_ADMIN`) ;
3. les helpers Shadow capability-aware conservent le mapping multi-UID complet avec seulement `SETGID|SETUID`. Un build et une exécution réels en `USER 2000` ont réussi après import OCI et remplacement du pod.

Une tentative avec des file capabilities sans bit setuid a aussi été écartée : le build OCI conservait les xattrs, mais le rootfs partagé dans l'invité Kata par virtiofs ne les exposait pas. Les deux helpers SUID contrôlés sont donc le compromis fonctionnel minimal sur cette installation.

Le VMM Kata côté hôte n'est pas nécessairement rootless. Le mode « rootless VMM » de runtime-rs est un réglage Kata distinct du mode rootless de Podman dans le workload.

## Système de fichiers et stockage

La racine de l'image est montée en lecture seule. Trois zones sont inscriptibles :

| Montage | Support | Usage |
|---|---|---|
| `/home/podman` | PVC `local-path`, 30 Gio | configuration code-server et workspace dans `/home/podman/workspace` |
| `/tmp` | `emptyDir.medium: Memory` | runtime et graphroot Podman |
| `/var/tmp` | `emptyDir` | temporaires applicatifs |

Les `emptyDir` disque sont présentés à la micro-VM en `virtiofs`. Sur ce chemin, l'OverlayFS rootless ne peut pas créer son upperdir. Le guest n'expose pas non plus `/dev/fuse`, ce qui exclut `fuse-overlayfs` sans ajouter de périphérique ou de `hostPath`.

Le profil validé place donc `runroot=/tmp/run-user-1000/containers` et `rootless_storage_path=/tmp/podman-storage`. Le volume `/tmp` est un tmpfs de 8 Gio ; le noyau invité accepte l'OverlayFS rootless natif avec `userxattr`. Cette solution évite le driver VFS et ses copies intégrales de couches.

Les caches à forte rotation sont également dirigés vers ce tmpfs : `XDG_CACHE_HOME`, le cache npm, le cache pip et `GOCACHE`. `TMPDIR=/tmp` y place aussi les fichiers temporaires des outils qui respectent cette variable. Le workspace, les extensions et les données utilisateur code-server restent sur le PVC. Cette séparation évite que les créations et suppressions de milliers de petits fichiers traversent virtiofs sans sacrifier les données à conserver.

Conséquences :

- les images et conteneurs intérieurs disparaissent avec le pod ;
- le home, les réglages et le workspace survivent au remplacement du pod grâce au PVC ;
- leur stockage consomme la mémoire attribuée au conteneur ;
- le `sizeLimit: 8Gi` déclaré pour `/tmp` ne garantit pas 8 Gio utilisables : avec environ 10 Gio de RAM invitée, le tmpfs observé est plafonné à environ 4,9 Gio ;
- le cache froid doit être distingué du cache chaud dans les mesures ;
- un stockage persistant futur doit être testé dans l'invité avec les mêmes probes de montage et de lancement.

## Réseau et exposition

Le guest Kata n'expose pas `/dev/net/tun`. `slirp4netns` et `pasta` ne peuvent donc pas créer leur interface par défaut. La configuration Podman utilise `netns="host"` pour les conteneurs intérieurs.

Le profil OCI non privilégié masque plusieurs chemins `/proc`; avec un namespace PID privé, `crun` échoue ici sur `mount proc: Operation not permitted`. Podman utilise donc aussi `pidns="host"` et `cgroups="enabled"`. Dans les deux cas, « host » désigne le namespace du **pod/micro-VM Kata**, pas celui du nœud K3s ni celui de Windows. Les conteneurs intérieurs voient la loopback et les PID du pod et peuvent agir sur les processus appartenant au même UID ; ce partage doit être pris en compte dans le modèle de menace. La micro-VM Kata reste la frontière face au nœud.

Code-server est exposé par un Service NodePort `30443` sur l'adresse de la VM Multipass. Le chemin `kubectl port-forward` de K3s ne rejoint pas le loopback de l'invité Kata dans cette configuration et n'est donc pas retenu. L'authentification par mot de passe reste active, mais le NodePort n'ajoute pas TLS : il est réservé au laboratoire local.

## Admission et échappements interdits

La `ValidatingAdmissionPolicy` appliquée au namespace labellisé exige :

- une RuntimeClass Kata approuvée ;
- exactement un conteneur nommé `code-server` ;
- un UID non nul explicite ;
- aucun `hostPath`, `hostPID`, `hostIPC`, `hostNetwork` ou `hostPort` ;
- aucun token de service account monté automatiquement ;
- aucun init container ni conteneur éphémère ;
- `privileged: false`, racine en lecture seule et groupes supplémentaires stricts ;
- l'allowlist exacte `drop: [ALL]`, `add: [SETGID, SETUID]`.

Le namespace conserve le niveau Pod Security `privileged` parce que le profil `Unconfined` requis par le Podman imbriqué est rejeté par les niveaux plus stricts. La politique CEL dédiée resserre ensuite le workload à la configuration exacte ci-dessus.

## Preuves d'acceptation

Le parcours WSL appelle `scripts/wsl/verify-workspace.sh` après chaque déploiement et bloque si une preuve échoue. Il constitue la vérification exhaustive de référence ; le script PowerShell historique conserve les contrôles principaux pour compatibilité :

1. le nœud et `kata-qemu-runtime-rs` existent, et la configuration containerd conserve `privileged_without_host_devices=true` comme défense en profondeur ;
2. l'image locale est présente dans le containerd K3s ;
3. le pod possède exactement un conteneur et demande la RuntimeClass Kata ;
4. le noyau invité diffère de celui du nœud ;
5. le processus principal est UID 1000, groupe unique 1000, avec les quatre jeux de capabilities actifs nuls et le bounding set exact `0xc0` ;
6. l'allowlist setid ne contient que les deux helpers Shadow `newuidmap/newgidmap`, en `4755 root:root` ;
7. Podman annonce `rootless=true`, `overlay`, le graphroot tmpfs attendu et aucun `mount_program` FUSE ;
8. `podman unshare` montre un mapping non-identité ;
9. `/healthz` répond ;
10. un conteneur Alpine épinglé par digest est téléchargé puis exécuté avec le mapping attendu ; une image `USER 2000` est ensuite construite et exécutée.

## Mesures de performance

Le point d'entrée WSL `scripts/wsl/benchmark-podman.sh` compare le profil Kata
réel (pod non privilégié, Podman rootless) au témoin explicitement demandé
sans restriction (pod runc privilégié, Podman rootful). Les deux emploient la
même image extérieure, la même image Alpine intérieure épinglée, les mêmes
limites de ressources et le driver VFS commun. Ce dernier évite de confondre
les résultats avec l'incompatibilité d'OverlayFS rootless sur tmpfs côté runc.

Le [rapport du 21 novembre 2026](benchmark-podman-20261121.md) conserve le
protocole, les limites et les résultats bruts associés.

Pour comparer cette cible à un runtime classique, effectuer au moins 30 itérations après une passe froide distincte :

1. temps `create` → `Ready` sous runc puis Kata ;
2. temps d'un `podman run --rm --pull=never ... true` ;
3. build réel cache froid puis cache chaud ;
4. consommation mémoire du tmpfs Podman au repos et sous build ;
5. I/O et métadonnées sur le graphroot tmpfs ;
6. débit et latence réseau avec le namespace du pod.

Conserver p50, p95, taille du cache et working set. Le tmpfs favorise les I/O mais augmente directement la pression mémoire ; un résultat ne peut pas être comparé à un graphroot disque sans le signaler.

## Limites et évolution

- Le workspace est persistant, mais le cache Podman reste éphémère.
- Le réseau intérieur n'est pas isolé de la loopback du pod.
- Les conteneurs intérieurs partagent les namespaces réseau et PID du pod Kata ; ils ne partagent pas ceux du nœud.
- `allowPrivilegeEscalation=true` et le seccomp invité non appliqué (`Seccomp: 0`) restent des limites ; l'allowlist de deux capabilities et la micro-VM sont les contrôles principaux.
- Le NodePort n'offre pas TLS et ne doit pas être exposé à un réseau non fiable.
- Une cible de production doit employer plusieurs nœuds, un stockage persistant compatible, des sauvegardes, une politique réseau vérifiée et une gestion centralisée des identités/secrets.

Une optimisation future ne doit jamais supprimer les preuves Kata/rootless, monter un socket du nœud, ni basculer Podman en rootful.
