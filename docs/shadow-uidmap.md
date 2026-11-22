# Pourquoi nous recompilons `newuidmap` et `newgidmap`

## Résultat recherché

L'objectif n'était pas seulement de faire démarrer Podman. Le profil retenu
devait conserver simultanément :

- un conteneur Kubernetes `privileged: false` ;
- Podman rootless avec un vrai mapping multi-UID/GID ;
- la compatibilité avec les images et builds utilisant `USER 2000` ;
- `CapBnd=00000000000000c0`, soit uniquement `SETGID|SETUID` ;
- `CapInh`, `CapPrm`, `CapEff` et `CapAmb` nuls pour code-server.

Deux capabilities sont le minimum **fonctionnel démontré sur cette pile**
K3s/Kata/Ubuntu. Ce résultat n'est pas présenté comme un minimum universel
pour toutes les versions de noyau, de runtime et de helpers.

## Pourquoi Podman appelle ces helpers

Podman rootless crée un user namespace, puis délègue l'écriture de ses
mappings aux programmes SUID contrôlés `newuidmap` et `newgidmap`. Ceux-ci :

1. identifient le véritable utilisateur appelant ;
2. valident les plages demandées avec `/etc/subuid` et `/etc/subgid` ;
3. écrivent `/proc/<pid>/uid_map` ou `/proc/<pid>/gid_map`.

Le mapping attendu est :

```text
         0       1000          1
         1     100000      65536
```

Dans le conteneur intérieur, l'UID 0 correspond donc à l'UID 1000 du
workspace. Les UID 1 à 65 536 utilisent la plage subordonnée 100000 à 165535.
La validation des plages est visible dans le code amont de
[`newuidmap.c`](https://raw.githubusercontent.com/shadow-maint/shadow/4.13/src/newuidmap.c)
et de
[`newgidmap.c`](https://raw.githubusercontent.com/shadow-maint/shadow/4.13/src/newgidmap.c).

## Résultats de la matrice live

Les cas suivants ont été exécutés dans des pods Kata séparés, avec la même
image et sans modifier le workload réel avant de disposer d'un candidat
fonctionnel :

| Enveloppe Kubernetes et helpers | Résultat observé |
|---|---|
| `drop ALL`, aucune addition, mapping mono-UID | une image root-only démarre, mais `USER 2000` échoue avec `setresgid: Invalid argument` |
| `SETUID,SETGID`, helpers Ubuntu SUID | `newuidmap: open of uid_map failed: Permission denied` |
| ajout de `DAC_OVERRIDE` | l'ouverture réussit, puis l'écriture de `uid_map` échoue avec `Operation not permitted` |
| ajout de `SYS_ADMIN` en plus | mapping multi-UID et Podman fonctionnent, avec `CapBnd=0x2000c2` |
| `privileged: true` | fonctionnel, mais bounding set complet `0x1ffffffffff` |
| file capabilities seules | visibles dans l'image du builder, absentes dans le rootfs du pod Kata |
| helpers Shadow capability-aware, `SETUID,SETGID` | mapping complet, `podman run`, build et exécution `USER 2000` réussis |

Cette matrice explique pourquoi une simple recommandation générique
« ajoutez `SETUID` et `SETGID` » ne suffisait pas avec les binaires Ubuntu
présents dans l'image initiale.

## Pourquoi le paquet Ubuntu stock demandait davantage

L'inspection live des helpers Ubuntu 24.04 a montré qu'ils ne contenaient pas
le chemin conditionnel compilé lorsque `HAVE_SYS_CAPABILITY_H` est disponible.
Après l'exec SUID, le helper restait donc EUID 0 au lieu de revenir à l'UID
réel 1000 tout en conservant uniquement sa capability de mapping.

Or le user namespace cible appartenait à l'UID 1000. Dans cette configuration
locale :

- `DAC_OVERRIDE` permettait à l'EUID 0 d'ouvrir le fichier proc du processus
  appartenant à l'UID 1000 ;
- `SYS_ADMIN` satisfaisait ensuite le contrôle de capacité sur le namespace
  cible ;
- `SETUID` ou `SETGID` restait requis pour autoriser le mapping dans le
  namespace parent.

Il ne faut pas en déduire que `newuidmap` exige toujours `SYS_ADMIN`. C'était
la conséquence du binaire stock, du propriétaire du namespace et de cette
pile d'exécution. Les règles générales sont implémentées dans
[`map_write()` et `new_idmap_permitted()` du noyau](https://raw.githubusercontent.com/torvalds/linux/master/kernel/user_namespace.c).

## Ce que change le build Shadow capability-aware

Le chemin `HAVE_SYS_CAPABILITY_H` de Shadow, dans
[`libmisc/idmapping.c`](https://raw.githubusercontent.com/shadow-maint/shadow/4.13/libmisc/idmapping.c),
utilise le mécanisme suivant autour de l'écriture du mapping :

- conservation contrôlée des capabilities lors du changement d'identité ;
- retour à l'UID réel de l'appelant, ici 1000 ;
- conservation temporaire de la seule capability pertinente,
  `CAP_SETUID` ou `CAP_SETGID` ;
- écriture du mapping puis fin du processus helper.

L'EUID du helper correspond alors au propriétaire du user namespace cible.
`DAC_OVERRIDE` et `SYS_ADMIN` peuvent disparaître du bounding set Kubernetes,
tandis que `SETUID|SETGID` suffit à créer les deux mappings subordonnés.

`CAP_SETFCAP` n'est pas requis ici : le mapping ne mappe pas l'UID 0 du
namespace parent vers l'UID 0 du namespace enfant. Il mappe le root intérieur
vers l'UID parent 1000. Les détails des règles de mapping sont également
décrits dans
[`user_namespaces(7)`](https://man7.org/linux/man-pages/man7/user_namespaces.7.html).

## Build traçable et source épinglée

La source est explicitement épinglée :

```text
Projet :  shadow-maint/shadow
Version : 4.13
SHA-256 : 9afe245d79a2e7caac5f1ed62519b17416b057ec89df316df1c3935502f9dd2c
```

L'image de base, la version Shadow et son archive sont déterministes et
vérifiées. Les paquets APT de compilation ne sont toutefois pas tous épinglés
à une révision : il s'agit d'un build traçable, pas d'une promesse de
reproductibilité bit-à-bit.

Le stage `uidmap-builder` du Dockerfile :

1. part de la même image Ubuntu 24.04 épinglée par digest ;
2. installe uniquement les dépendances de compilation, dont `libcap-dev` ;
3. télécharge l'archive de la
   [release Shadow 4.13](https://github.com/shadow-maint/shadow/releases/tag/4.13) ;
4. vérifie son SHA-256 avant extraction ;
5. désactive les fonctionnalités Shadow inutiles au build des helpers ;
6. exige littéralement `#define HAVE_SYS_CAPABILITY_H 1` dans `config.h` ;
7. compile et strippe `newuidmap/newgidmap` ;
8. copie uniquement ces deux binaires dans l'image finale en `4755 root:root`.

Le paquet Ubuntu `uidmap` reste installé pour son intégration et ses fichiers
de support, mais ses deux exécutables sont remplacés. Les outils de build et
`libcap-dev` n'entrent pas dans l'image finale grâce au build multi-stage.

## Alternatives écartées

### Zéro capability et mapping mono-UID

Avec des fichiers `/etc/subuid` et `/etc/subgid` vides et
`ignore_chown_errors=true`, Podman peut extraire et lancer certaines images
root-only. Tous les propriétaires sont cependant aplatis sur un seul UID.

Le test décisif a construit une image contenant `USER 2000`. Le runtime a
échoué sur `setresgid(2000)` car cet identifiant n'existait pas dans le mapping.
Cette variante ne convient donc pas à un environnement de développement
généraliste, où les images Node, Python ou VS Code utilisent fréquemment un
utilisateur non-root.

### File capabilities sans bit SUID

La variante suivante était plus élégante en théorie :

```text
/usr/bin/newuidmap cap_setuid=ep
/usr/bin/newgidmap cap_setgid=ep
```

Les xattrs étaient présents lors du test de la couche OCI et dans l'image du
builder. Après import dans containerd et démarrage par Kata, `getcap` ne
retournait cependant plus rien dans le guest. Sur cette installation, le
rootfs d'image partagé avec l'invité par virtio-fs n'exposait pas ces xattrs.

C'est un constat propre à cette pile, pas une affirmation universelle sur
virtio-fs. La spécification OCI décrit les attributs étendus « lorsque le
système les prend en charge » dans les
[attributs des layers OCI](https://github.com/opencontainers/image-spec/blob/main/layer.md#file-attributes),
et Kata explique le partage habituel du rootfs par virtio-fs dans son
[guide d'architecture](https://github.com/kata-containers/kata-containers/blob/main/docs/quick-start-guide.md#what-is-kata-containers).

### Quatre capabilities avec les helpers stock

`DAC_OVERRIDE|SETGID|SETUID|SYS_ADMIN` était fonctionnel, avec un processus
code-server toujours sans capability effective. `SYS_ADMIN` reste néanmoins
une capability très large dans le noyau invité. Recompiler deux petits helpers
amont permet précisément de supprimer ce fallback du bounding set.

### Conteneur Kubernetes privilégié

Le profil initial `privileged: true` donnait un bounding set complet dans la
micro-VM. Même si Kata protégeait encore le nœud, cela élargissait inutilement
la surface d'attaque du noyau invité. Il a été remplacé par
`privileged: false` et l'allowlist exacte de deux capabilities.

## Coût de sécurité et contrôles compensatoires

Le compromis retenu doit rester explicite :

- deux fichiers restent SUID root ;
- `allowPrivilegeEscalation: true` et `NoNewPrivs: 0` sont nécessaires ;
- `no_new_privs` neutraliserait sinon les transitions SUID, comme l'explique
  la [documentation du noyau](https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html) ;
- la configuration Kata actuelle affiche `Seccomp: 0`, limite distincte de la
  réduction des capabilities.

Les contrôles compensatoires sont vérifiés à chaque déploiement :

- source Shadow et SHA-256 épinglés ;
- compilation obligatoire avec `HAVE_SYS_CAPABILITY_H=1` ;
- seuls `/usr/bin/newuidmap` et `/usr/bin/newgidmap` peuvent être setid ;
- propriétaires et modes exacts `4755 root:root` ;
- tous les autres bits setuid/setgid supprimés de l'image ;
- `supplementalGroupsPolicy: Strict`, groupe effectif unique 1000 ;
- politique d'admission : `privileged: false`, `drop ALL`, ajout exact
  `SETGID,SETUID` ;
- `CapInh`, `CapPrm`, `CapEff` et `CapAmb` nuls pour le processus persistant ;
- micro-VM Kata comme frontière avec le nœud Kubernetes.

## Preuves de non-régression

Dans le pod :

```bash
grep -E '^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):' \
  /proc/1/status

find /usr -xdev -type f -perm /6000 \
  -printf '%m %u:%g %p\n' | sort

podman unshare cat /proc/self/uid_map
podman unshare cat /proc/self/gid_map
podman info --format '{{.Host.Security.Rootless}}'
```

Résultats attendus :

```text
CapInh:       0000000000000000
CapPrm:       0000000000000000
CapEff:       0000000000000000
CapBnd:       00000000000000c0
CapAmb:       0000000000000000
NoNewPrivs:   0

4755 0:0 /usr/bin/newgidmap
4755 0:0 /usr/bin/newuidmap

uid/gid map:
0 1000 1
1 100000 65536

rootless=true
```

La preuve fonctionnelle qui empêche une régression vers le mode mono-UID est
un vrai build :

```Dockerfile
FROM docker.io/library/alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2
USER 2000:2000
RUN id -u | grep -qx 2000
CMD ["id", "-u"]
```

Le build puis le run doivent rendre `2000`, après import OCI et remplacement
complet du pod. `scripts/wsl/verify-workspace.sh` automatise cette preuve.
