# Bootstrap Hyper-V de la VM Kata

Ce document couvre la seule partie volontairement Windows du laboratoire : préparer l'hyperviseur, Multipass et la virtualisation imbriquée. Les opérations quotidiennes sont ensuite réalisées depuis WSL avec les scripts Bash du dépôt.

## Pourquoi une VM Multipass séparée

Le nœud Kubernetes validé n'est pas la distribution WSL. Il s'agit d'une vraie VM Ubuntu 24.04 de génération 2 dans Hyper-V :

- VM `kata-k8s` ;
- 8 vCPU, 16 Gio de RAM statique et 100 Gio de disque par défaut ;
- K3s `v1.37.2+k3s1` ;
- Kata Containers `4.4.0` ;
- RuntimeClass unique `kata-qemu-runtime-rs` ;
- `/dev/kvm`, `/dev/vhost-vsock` et `/dev/vhost-net` dans le nœud.

Cette couche garantit que Kata peut lancer une micro-VM matérielle. Le projet refuse volontairement l'émulation QEMU logicielle.

## Amorçage Windows ponctuel

Depuis une console PowerShell **administrateur** :

```powershell
Set-Location C:\chemin\vers\code-server-kata
.\scripts\windows\New-HyperVKataCluster.ps1
```

Ce script :

1. active Hyper-V et `hypervisorlaunchtype=auto` ;
2. installe ou retrouve Multipass et sélectionne son backend Hyper-V ;
3. crée ou réutilise la VM `kata-k8s` ;
4. applique `Set-VMProcessor -ExposeVirtualizationExtensions $true` ;
5. désactive les checkpoints automatiques et fixe la mémoire ;
6. provisionne K3s et Kata puis exécute un smoke test matériel ;
7. écrit le kubeconfig sous `.state/hyperv-kata/kata-k8s.kubeconfig`.

Si le script signale `RESTART_REQUIRED`, redémarrer Windows puis exécuter la même commande. Il ne redémarre pas l'hôte automatiquement.

Ces actions restent en PowerShell parce que WSL ne peut pas appeler nativement `Enable-WindowsOptionalFeature`, `bcdedit`, `Get-VM` ou `Set-VMProcessor` avec les privilèges administrateur nécessaires.

## Connectivité WSL vers la VM

Le NAT WSL par défaut peut ne pas router le sous-réseau privé Multipass. Le parcours Linux natif exige alors le réseau WSL miroir. Dans `%UserProfile%\.wslconfig` :

```ini
[wsl2]
networkingMode=mirrored
```

Puis, depuis PowerShell ou `cmd.exe` :

```powershell
wsl --shutdown
```

Rouvrir la distribution WSL et exécuter `make doctor`. Le script vérifie rapidement l'accès à l'API Kubernetes et fournit ce diagnostic si l'IP Multipass reste inaccessible.

## Retour au workflow WSL

Dans WSL :

```bash
cd /mnt/c/chemin/vers/code-server-kata
make doctor
make check
make deploy
```

Pour reprovisionner uniquement K3s/Kata dans une VM Hyper-V déjà préparée :

```bash
make cluster
```

`make cluster` transfère `scripts/linux/Install-K3sKata.sh` dans la VM, réinstalle/répare K3s et Kata, puis récupère le kubeconfig sans modifier le contexte Kubernetes global.

## Vérifications manuelles

Depuis WSL :

```bash
export KUBECONFIG="$PWD/.state/hyperv-kata/kata-k8s.kubeconfig"
kubectl get nodes -o wide
kubectl get runtimeclass kata-qemu-runtime-rs
make shell
```

Dans la VM :

```bash
grep -E '(vmx|svm)' /proc/cpuinfo | head
ls -l /dev/kvm /dev/vhost-vsock /dev/vhost-net
```

L'installation échoue si ces ressources ne sont pas utilisables. Avant de réussir, elle démarre un pod Kata et vérifie que son noyau diffère de celui du nœud Ubuntu.
