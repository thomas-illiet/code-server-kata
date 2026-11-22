# Piloter le laboratoire depuis WSL

## Positionnement

WSL est le plan de contrôle quotidien du dépôt. Les commandes de validation,
de provisionnement de l'invité, de build, de déploiement et de vérification
s'exécutent en Bash depuis WSL 2.

WSL **n'héberge pas** le cluster Kata :

```text
Windows 11
├─ WSL 2 — terminal et outils de contrôle Linux
└─ Multipass/Hyper-V
   └─ VM Ubuntu `kata-k8s`
      └─ K3s + containerd + Kata Containers
         └─ micro-VM Kata du pod code-server
```

La distinction est importante. Le noyau WSL, le noyau du nœud K3s et le
noyau de la micro-VM Kata sont trois environnements différents. L'isolation
du workload face au nœud est fournie par Kata dans la VM Multipass, pas par
WSL.

## Frontière Windows incompressible

Les opérations suivantes restent propres à Windows et nécessitent une console
PowerShell administrateur :

- activer Hyper-V et le lancement de l'hyperviseur ;
- installer et sélectionner le backend Hyper-V de Multipass ;
- créer ou configurer la VM Hyper-V ;
- exécuter `Set-VMProcessor -ExposeVirtualizationExtensions $true` ;
- redémarrer Windows lorsqu'une fonctionnalité hôte vient d'être activée.

Le bootstrap existant prend en charge cette phase :

```powershell
Set-Location C:\chemin\vers\code-server-kata
.\scripts\windows\New-HyperVKataCluster.ps1
```

Cette commande est un amorçage ponctuel. Une fois la VM `kata-k8s` créée et
la virtualisation imbriquée exposée, revenir dans WSL. Les scripts PowerShell
restent disponibles pour compatibilité, mais ne constituent plus le parcours
normal.

## Préparer WSL

Une distribution Ubuntu WSL 2 est recommandée. Le dépôt présent sur le disque
Windows est accessible avec un chemin Linux :

```bash
cd /mnt/c/chemin/vers/code-server-kata
```

Installer ou vérifier les outils Linux :

```bash
make tools
make doctor
```

Le parcours WSL utilise notamment :

- Bash, `make`, `curl`, `jq` et les utilitaires GNU ;
- un `kubectl` **Linux natif** dans WSL ;
- le client Multipass Windows par l'interop WSL.

Les scripts recherchent Multipass dans le `PATH`, puis aux emplacements :

```text
/mnt/c/Program Files/Multipass/bin/multipass.exe
/mnt/c/Program Files/Canonical/Multipass/bin/multipass.exe
```

Lorsqu'un chemin local est transmis à un exécutable Windows, il est converti
avec `wslpath -w`. Les commandes Kubernetes, elles, utilisent toujours des
chemins WSL.

## Connectivité vers la VM Multipass

Le NAT WSL par défaut ne route pas toujours le sous-réseau privé utilisé par
Multipass/Hyper-V. Le symptôme est un kubeconfig correct, mais une API telle
que `https://172.x.x.x:6443` injoignable depuis WSL. `make doctor` teste ce
chemin avec un délai court et l'explique explicitement.

Dans ce cas, créer ou compléter `%UserProfile%\.wslconfig` côté Windows :

```ini
[wsl2]
networkingMode=mirrored
```

Puis, depuis PowerShell :

```powershell
wsl.exe --shutdown
```

Rouvrir WSL et relancer `make doctor`. Ce réglage concerne la connectivité du
poste de contrôle WSL vers la VM ; il ne déplace ni K3s ni Kata dans WSL.

## Parcours principal

Depuis la racine du dépôt :

```bash
make doctor
make check
make cluster
make deploy
make verify
make status
```

Les cibles ont les responsabilités suivantes :

| Cible | Rôle |
|---|---|
| `make doctor` | vérifie WSL 2, les outils, Multipass, la VM et le kubeconfig |
| `make check` | valide la syntaxe Bash, les pins, le Dockerfile et les overlays Kustomize |
| `make cluster` | provisionne ou répare K3s et Kata dans la VM Multipass **existante** |
| `make deploy` | construit l'image, l'importe dans K3s, applique les manifestes et vérifie le résultat |
| `make deploy-fast` | redéploie sans reconstruire l'image déjà importée |
| `make verify` | rejoue toutes les preuves de sécurité et de fonctionnement |
| `make benchmark` | compare Podman rootful dans runc privilégié à Podman rootless dans Kata |
| `make status` | affiche l'état du nœud, de la RuntimeClass, du pod, du PVC et du Service |
| `make shell` | ouvre un shell dans la VM `kata-k8s` |

`make cluster` ne peut pas activer Hyper-V ni exposer la virtualisation
imbriquée. Il suppose que le bootstrap Windows précédent a déjà préparé la VM.
Il transfère ensuite l'installeur Linux, installe K3s/Kata et récupère le
kubeconfig.

### Benchmark Podman

Le benchmark reproductible se lance avec :

```bash
BENCHMARK_ITERATIONS=10 make benchmark
```

Il crée un namespace temporaire, préchauffe les images, alterne l'ordre des
profils puis mesure `podman run`, une écriture synchronisée de 128 Mio et un
build sans cache en `USER 2000`. Le témoin demandé « sans restriction » est
un pod runc privilégié exécutant Podman rootful ; Kata reste non privilégié et
Podman rootless. Les profils diffèrent donc volontairement et le résultat ne
doit pas être présenté comme le seul coût de la micro-VM.

Les CSV sont écrits dans `benchmark-results/`, puis le namespace temporaire
est supprimé. Voir le [rapport de référence du 21 novembre
2026](benchmark-podman-20261121.md).

## Kubeconfig

Le fichier par défaut est :

```text
.state/hyperv-kata/kata-k8s.kubeconfig
```

En WSL :

```bash
export KUBECONFIG="$PWD/.state/hyperv-kata/kata-k8s.kubeconfig"
kubectl get nodes -o wide
kubectl get runtimeclass kata-qemu-runtime-rs
```

Les scripts passent explicitement `--kubeconfig`; ils ne remplacent pas le
contexte Kubernetes global de l'utilisateur.

## Déployer le workspace

Le déploiement conserve un Secret existant. Pour générer un nouveau mot de
passe automatiquement :

```bash
make deploy
```

Pour imposer une valeur, utiliser un fichier temporaire protégé afin de ne pas
placer le secret dans les arguments du processus ni dans l'historique shell :

```bash
read -rsp 'Nouveau mot de passe: ' password
printf '%s' "$password" > /tmp/code-server-password
unset password
chmod 600 /tmp/code-server-password
bash ./scripts/wsl/deploy-workspace.sh \
  --skip-image-build \
  --password-file /tmp/code-server-password
rm -f /tmp/code-server-password
```

Le script ne réaffiche jamais le mot de passe. Pour le relire explicitement :

```bash
kubectl --kubeconfig "$KUBECONFIG" -n code-server \
  get secret code-server-auth -o jsonpath='{.data.PASSWORD}' |
  base64 --decode
printf '\n'
```

Le home et le workspace persistent dans le PVC `code-server-home`. Le build
ou le remplacement du pod ne supprime pas ce PVC.

## Accéder à code-server

Le Service expose le NodePort `30443` sur l'adresse interne de la VM
Multipass :

```bash
node_ip="$(kubectl --kubeconfig "$KUBECONFIG" get node kata-k8s \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
printf 'http://%s:30443\n' "$node_ip"
```

L'IP peut changer si la VM est recréée ; la commande ci-dessus reste la source
de vérité. Le NodePort n'ajoute pas TLS et doit rester limité au laboratoire
local.

## Ce que vérifie `make verify`

La vérification échoue si une preuve manque :

- un seul conteneur, RuntimeClass `kata-qemu-runtime-rs` ;
- `privileged: false`, `drop: [ALL]`, ajout exact `SETGID,SETUID` ;
- `CapBnd=00000000000000c0` et jeux effectif, permis, hérité et ambiant nuls ;
- groupe effectif unique `1000` ;
- seuls `newuidmap/newgidmap` en `4755 root:root` ;
- mappings UID et GID `0→1000`, puis `1→100000` sur 65 536 identifiants ;
- Podman rootless, OverlayFS natif et graphroot dans `/tmp` ;
- exécution d'un conteneur épinglé par digest ;
- build et exécution d'une image en `USER 2000` ;
- deux requêtes `dry-run=server` prouvent que la politique d'admission rejette
  `privileged: true` et l'ajout de `SYS_ADMIN` ;
- réponse HTTP du NodePort.

Les raisons du build particulier de `newuidmap/newgidmap` sont détaillées dans
[Pourquoi nous recompilons Shadow](shadow-uidmap.md).

## Variables et options usuelles

Les valeurs par défaut sont la VM `kata-k8s`, le namespace `code-server` et le
kubeconfig sous `.state/hyperv-kata`. Les points d'entrée Bash acceptent des
options explicites :

```bash
./scripts/wsl/deploy-workspace.sh --help
./scripts/wsl/verify-workspace.sh --help
./scripts/wsl/provision-cluster.sh --help
```

Le namespace est volontairement fixé à `code-server`. La politique
d'admission et les références au Secret/PVC sont conçues comme un ensemble ;
un remplacement partiel du nom pourrait donner une fausse impression de
sécurité.

## Dépannage

### `multipass.exe` introuvable

Vérifier d'abord Windows :

```bash
'/mnt/c/Program Files/Multipass/bin/multipass.exe' version
```

Si le fichier n'existe pas, installer Multipass côté Windows. Ne pas installer
un second daemon Multipass dans WSL : la VM validée appartient au service
Windows et au backend Hyper-V.

### La VM n'existe pas

`make cluster` ne crée pas la couche Hyper-V. Exécuter le bootstrap PowerShell
administrateur, redémarrer Windows si demandé, puis revenir dans WSL.

### `/dev/kvm` absent dans la VM

Dans la VM :

```bash
make shell
grep -E '(vmx|svm)' /proc/cpuinfo | head
ls -l /dev/kvm /dev/vhost-vsock /dev/vhost-net
```

Si les drapeaux CPU ou `/dev/kvm` manquent, arrêter la VM et réappliquer
`Set-VMProcessor -ExposeVirtualizationExtensions $true` depuis PowerShell
administrateur. Le projet refuse volontairement l'émulation QEMU logicielle.

### Le kubeconfig pointe vers `127.0.0.1`

Relancer `make cluster`. L'installeur réécrit l'endpoint avec l'IP de la VM
avant de restituer le kubeconfig à WSL.

### L'API Kubernetes est injoignable depuis WSL

Si l'adresse du kubeconfig est bien l'IP Multipass mais que `make doctor`
échoue au test de connexion, activer `networkingMode=mirrored` comme décrit
dans [Connectivité vers la VM Multipass](#connectivité-vers-la-vm-multipass),
puis arrêter complètement WSL avec `wsl.exe --shutdown`.

### Le pod démarre mais Podman échoue sur `/proc`

Vérifier la configuration embarquée :

```bash
kubectl --kubeconfig "$KUBECONFIG" -n code-server exec deploy/code-server-podman -- \
  grep -E '^(cgroups|netns|pidns)' /etc/containers/containers-rootless.conf
```

Les valeurs attendues sont `cgroups="enabled"`, `netns="host"` et
`pidns="host"`. Ici, `host` désigne le pod/la micro-VM Kata, jamais le nœud
K3s.

### `Seccomp: 0`

La configuration Kata actuelle ne transmet pas de filtre seccomp au guest.
C'est une limite connue et distincte du travail sur les capabilities. La
micro-VM Kata et l'allowlist `SETGID|SETUID` restent les contrôles principaux ;
il ne faut pas présenter le profil `Unconfined` comme un confinement seccomp.

## Voies supportées

La voie validée et documentée est :

```text
WSL → Multipass/Hyper-V → Ubuntu → K3s → Kata QEMU runtime-rs
```

Les fichiers historiques relatifs à Podman Machine, kind et MSHV restent dans
le dépôt pour comparaison ou compatibilité, mais ils ne constituent pas la
cible testée par le parcours `make deploy`.
