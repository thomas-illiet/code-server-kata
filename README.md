# code-server + Podman rootless dans Kata Containers

Ce dépôt fournit un environnement de développement dans **un seul conteneur Kubernetes** : code-server et Podman rootless tournent sous l'UID/GID 1000, dans une micro-VM Kata dédiée. Le parcours local principal est conçu pour **WSL 2 + Bash**. Windows ne sert qu'à l'amorçage Hyper-V et à Multipass. Un overlay de production distinct remplace le NodePort par un Service interne et un Ingress TLS ; il exige une image publiée par digest, un stockage durable et un gestionnaire de secrets.

```text
Windows 11 / Hyper-V
└─ Multipass VM Ubuntu 24.04 `kata-k8s`
   └─ K3s + containerd + Kata QEMU
      └─ pod `code-server-podman` — RuntimeClass Kata
         └─ unique conteneur Ubuntu 24.04, UID/GID 1000
            ├─ code-server
            ├─ Podman rootless
            └─ conteneurs de développement rootless

WSL 2
└─ plan de contrôle quotidien : make, bash, kubectl, jq, curl
```

WSL n'héberge pas le nœud Kubernetes : il orchestre la VM Multipass qui porte réellement K3s, Kata et `/dev/kvm`. Cette séparation évite de présenter WSL comme une frontière d'isolation qu'il n'est pas.

## Démarrage rapide local

Prérequis : Windows avec Hyper-V, WSL 2, une distribution Ubuntu/Debian et un processeur permettant la virtualisation imbriquée. Après clonage du dépôt, amorcez une fois la VM depuis une console PowerShell administrateur :

```powershell
Set-Location C:\chemin\vers\code-server-kata
.\scripts\windows\New-HyperVKataCluster.ps1
```

Effectuez ensuite les opérations quotidiennes depuis WSL :

```bash
cd /mnt/c/chemin/vers/code-server-kata

make doctor
make check
make deploy
make verify
```

Si `make doctor` indique que l'API Kubernetes de la VM Multipass est
injoignable depuis WSL, activer le réseau miroir dans
`%UserProfile%\.wslconfig`, puis exécuter `wsl.exe --shutdown` depuis
PowerShell avant de rouvrir WSL. La configuration exacte et son diagnostic
sont détaillés dans [le guide WSL](docs/wsl.md#connectivité-vers-la-vm-multipass).

Pour un redéploiement sans reconstruire l'image :

```bash
make deploy-fast
```

Les commandes principales sont :

| Commande | Effet |
|---|---|
| `make tools` | installe les outils Linux nécessaires dans WSL |
| `make doctor` | vérifie WSL 2, kubectl, Multipass, la VM et le kubeconfig |
| `make versions-check` | vérifie la cohérence des versions, checksums et digests |
| `make repository-check` | recherche les secrets, chemins personnels et artefacts locaux |
| `make cluster` | provisionne ou répare K3s/Kata dans la VM existante |
| `make check` | exécute les validations statiques Bash/Kustomize |
| `make release-check` | exécute toutes les portes locales avant publication |
| `make deploy` | construit, importe, déploie et vérifie le workspace |
| `make deploy-fast` | redéploie sans reconstruire l'image |
| `make verify` | rejoue toutes les preuves runtime et un build `USER 2000` |
| `make benchmark` | compare Podman runc privilégié/rootful à Kata non privilégié/rootless |
| `make status` | affiche le nœud, la RuntimeClass, le pod, le PVC et le Service |
| `make shell` | ouvre un shell dans la VM Multipass |

Le kubeconfig par défaut est :

```text
.state/hyperv-kata/kata-k8s.kubeconfig
```

Toutes les commandes acceptent aussi les variables `VM_NAME` et `KUBECONFIG` du `Makefile`.

## Détails de l’amorçage Windows

Les opérations suivantes ne peuvent pas être réalisées nativement par Bash dans WSL : activation Hyper-V, installation/sélection du driver Multipass et `Set-VMProcessor -ExposeVirtualizationExtensions $true`. Depuis une console PowerShell **administrateur**, une seule fois :

```powershell
Set-Location C:\chemin\vers\code-server-kata
.\scripts\windows\New-HyperVKataCluster.ps1
```

Après ce bootstrap, revenir dans WSL pour les opérations courantes. Le script PowerShell de déploiement reste disponible comme compatibilité, mais n'est plus le parcours principal.

Voir [le guide WSL complet](docs/wsl.md) et [le bootstrap Hyper-V](docs/hyperv-kata.md).

## Accéder à code-server

Le Service utilise le NodePort `30443`. L'adresse du nœud est l'IP interne de la VM Multipass :

```bash
export KUBECONFIG="$PWD/.state/hyperv-kata/kata-k8s.kubeconfig"
node_ip="$(kubectl get node kata-k8s -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
printf 'http://%s:30443\n' "$node_ip"
```

L'adresse de la VM peut changer après une recréation ; l'URL produite par la
commande ci-dessus reste la source de vérité.

Le mot de passe reste dans le Secret Kubernetes et n'est jamais affiché par les scripts :

```bash
kubectl -n code-server get secret code-server-auth \
  -o jsonpath='{.data.PASSWORD}' | base64 --decode
printf '\n'
```

Pour imposer un nouveau mot de passe sans le stocker dans le dépôt :

```bash
read -rsp 'Nouveau mot de passe: ' password
printf '%s' "$password" > /tmp/code-server-password
unset password
chmod 600 /tmp/code-server-password
bash ./scripts/wsl/deploy-workspace.sh \
  --kubeconfig "$KUBECONFIG" \
  --password-file /tmp/code-server-password \
  --skip-image-build
rm -f /tmp/code-server-password
```

En production, fournissez plutôt `code-server-auth` depuis un gestionnaire de secrets externe.

## Profil de sécurité validé

Le pod réel est vérifié avec les propriétés suivantes :

- exactement un conteneur `code-server` et aucune sidecar/init/ephemeral container ;
- `runtimeClassName: kata-qemu-runtime-rs` ;
- `privileged: false`, racine en lecture seule et aucun `hostPath` ;
- UID/GID 1000, `supplementalGroupsPolicy: Strict`, groupe effectif unique 1000 ;
- `capabilities.drop: [ALL]`, puis ajout exact de `SETGID` et `SETUID` ;
- `CapInh`, `CapPrm`, `CapEff` et `CapAmb` nuls ;
- `CapBnd=00000000000000c0`, soit seulement `SETGID|SETUID` ;
- seuls `/usr/bin/newuidmap` et `/usr/bin/newgidmap` sont SUID (`4755 root:root`) ;
- mappings UID/GID `0 → 1000`, puis `1 → 100000` sur 65 536 identifiants ;
- Podman `rootless=true`, stockage OverlayFS natif sur `/tmp` ;
- `podman run`, build et exécution d'une image `USER 2000` réussis ;
- politique d'admission refusant `privileged: true`, `SYS_ADMIN` ou toute capability supplémentaire.

La variante à zéro capability a été testée : elle fonctionne seulement avec un mapping mono-UID et casse les images multi-utilisateurs. Le paquet Ubuntu `uidmap` stock exigeait, sur cette pile, `DAC_OVERRIDE` et `SYS_ADMIN` en plus de `SETUID/SETGID`. C'est la raison pour laquelle `newuidmap/newgidmap` sont recompilés depuis Shadow 4.13 avec le chemin capability-aware activé. La source et son SHA-256 sont épinglés.

Le raisonnement, la matrice d'essais et les règles noyau sont détaillés dans [Pourquoi nous recompilons Shadow](docs/shadow-uidmap.md).

## Stockage et namespaces intérieurs

- `/home/podman` est un PVC `local-path` de 30 Gio. Le workspace persistant est `/home/podman/workspace`.
- `/tmp` est un `emptyDir` en mémoire de 8 Gio et porte le graphroot Podman éphémère.
- les caches XDG, npm, pip, Go et les fichiers temporaires sont dirigés vers `/tmp` pour éviter les métadonnées virtiofs du PVC ;
- `/var/tmp` est un `emptyDir` disque de 2 Gio.
- Le rootfs du conteneur Kubernetes reste en lecture seule.
- Le guest n'expose ni `/dev/fuse` ni `/dev/net/tun`.
- Les conteneurs Podman utilisent `netns="host"` et `pidns="host"`. « host » désigne ici uniquement le pod/la micro-VM Kata, jamais le nœud K3s ou Windows.

Le partage PID permet aux workloads intérieurs de voir et de signaler les processus du même UID dans le pod. `allowPrivilegeEscalation=true`, `NoNewPrivs=0` et `Seccomp=0` restent aussi des limites explicites. La micro-VM Kata et l'allowlist de deux capabilities sont les contrôles principaux face au nœud.

## Voies supportées

La voie maintenue et validée est :

```text
WSL → Multipass Hyper-V → K3s → Kata QEMU runtime-rs
```

Les anciens scripts `Install-Cluster.ps1`, `Verify-Cluster.ps1`, `Benchmark.ps1`, ainsi que les profils kind/Podman Machine/MShv, sont conservés pour référence et compatibilité. Ils ne constituent pas le parcours recommandé.

## Déploiement de production

Le profil local ne doit pas être exposé directement sur Internet. Le modèle de production se trouve dans [`k8s/overlays/production`](k8s/overlays/production/README.md) et échoue volontairement tant que l’image immuable, le nom DNS TLS et le stockage ne sont pas configurés. Les exigences d’identité, sauvegarde, observabilité, registre, scan et rollback sont détaillées dans [le guide de production](docs/production.md).

La CI valide Linux, Windows, Kustomize, Helm et la construction complète de l’image. Le workflow `Publish workspace image` peut publier dans GHCR, sur tag Git ou déclenchement manuel, avec SBOM et provenance OCI ; son digest affiché doit ensuite remplacer le digest nul de l’overlay production.

Avant toute publication du dépôt lui-même, exécutez `make release-check` et choisissez explicitement une licence ; aucune licence n’est imposée automatiquement par ce projet.

## Documentation

- [Guide d'utilisation WSL](docs/wsl.md)
- [Pourquoi Shadow est recompilé](docs/shadow-uidmap.md)
- [Architecture, sécurité et performance](docs/architecture-performance.md)
- [Résultat du benchmark Podman](docs/benchmark-podman-20261121.md)
- [Mesures et stratégie de stockage](docs/storage-performance.md)
- [Bootstrap Hyper-V/Kata](docs/hyperv-kata.md)
- [Passage en production](docs/production.md)
- [Mises à jour et rollback](docs/upgrading.md)
- [Politique de sécurité](SECURITY.md)
- [Guide de contribution](CONTRIBUTING.md)

## Références amont

- [Kubernetes RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [Kubernetes security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Podman rootless](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
- [Shadow 4.13](https://github.com/shadow-maint/shadow/releases/tag/4.13)
- [Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)
- [Kata Containers](https://github.com/kata-containers/kata-containers)
