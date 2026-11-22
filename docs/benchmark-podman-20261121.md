# Benchmark Podman : runc sans restriction contre Kata rootless

## Résumé

Le test a été exécuté le 21 novembre 2026 sur le nœud local `kata-k8s`, avec
10 échantillons chauds par profil et par métrique après une passe de
préchauffage.

| Métrique | runc privilégié/rootful, moyenne | Kata non privilégié/rootless, moyenne | Ratio Kata/runc |
|---|---:|---:|---:|
| `podman run --rm … true` | 69,315 ms | 292,117 ms | 4,21× |
| `podman run` + écriture synchronisée de 128 Mio | 97,158 ms | 324,523 ms | 3,34× |
| build sans cache, couche 32 Mio et `USER 2000` | 1 282,281 ms | 2 262,134 ms | 1,76× |

Kata ajoute donc environ 223 ms au lancement trivial, 227 ms au lancement
avec écriture et 980 ms au build moyen dans ce laboratoire.

## Profils comparés

Le profil `runc-insecure` correspond à la demande « root full sans
restriction » :

- runtime Kubernetes par défaut `runc` ;
- pod `privileged: true`, UID/GID 0 et racine inscriptible ;
- seccomp `Unconfined` et Podman rootful.

Le profil `kata` conserve le modèle du workspace :

- RuntimeClass `kata-qemu-runtime-rs` ;
- pod non privilégié sous UID/GID 1000 ;
- `drop: [ALL]`, ajout limité à `SETGID|SETUID` ;
- Podman rootless et helpers Shadow capability-aware.

Il s'agit d'une comparaison de deux **profils complets**, pas d'une mesure
isolée du coût de Kata. La différence inclut la micro-VM, le noyau invité,
rootless contre rootful et le profil de sécurité.

## Conditions communes

- nœud : 8 vCPU, environ 16 Gio, K3s `containerd://2.3.7-k3s1` ;
- noyau du nœud/runc : `6.8.0-147-generic` ;
- noyau invité Kata : `6.18.62` ;
- Podman `4.9.3` ;
- image extérieure `localhost/code-server-podman:4.146.0-ubuntu24.04` ;
- image intérieure Alpine 3.23 épinglée par SHA-256 dans `versions.psd1` ;
- limites identiques : 2 CPU, 2 Gio de mémoire ;
- stockage Podman VFS sur le même type de tmpfs, cache chaud ;
- ordre runc/Kata alterné à chaque itération ;
- le pod code-server existant est resté actif, ce qui représente un léger
  bruit de fond identique pour toute la série.

VFS est utilisé comme dénominateur commun du benchmark. Le profil de
production Kata reste en OverlayFS natif et sera plus représentatif de
l'usage quotidien que ces chiffres VFS. Le premier essai a confirmé que le
pod runc rootless non privilégié ne pouvait pas utiliser OverlayFS sur tmpfs,
puis ne pouvait pas extraire l'image en VFS à cause d'un `remount /` refusé.

## Résultats détaillés

| Profil | Métrique | n | p50 | p95 | moyenne |
|---|---|---:|---:|---:|---:|
| runc privilégié/rootful | lancement trivial | 10 | 69,703 ms | 72,527 ms | 69,315 ms |
| Kata non privilégié/rootless | lancement trivial | 10 | 290,083 ms | 307,320 ms | 292,117 ms |
| runc privilégié/rootful | écriture synchronisée 128 Mio | 10 | 94,928 ms | 104,562 ms | 97,158 ms |
| Kata non privilégié/rootless | écriture synchronisée 128 Mio | 10 | 316,179 ms | 371,739 ms | 324,523 ms |
| runc privilégié/rootful | build `USER 2000` | 10 | 1 192,887 ms | 1 466,013 ms | 1 282,281 ms |
| Kata non privilégié/rootless | build `USER 2000` | 10 | 1 932,972 ms | 2 650,905 ms | 2 262,134 ms |

Avec seulement 10 échantillons, le p95 correspond pratiquement au maximum de
la série. Utiliser au moins 30 itérations et plusieurs séries indépendantes
avant une décision de capacité.

## Reproduction et données

Depuis WSL, après avoir rendu l'API K3s joignable :

```bash
BENCHMARK_ITERATIONS=10 make benchmark
```

Les échantillons exacts de cette série sont dans
`benchmark-results/20261121T164628Z-podman-raw.csv`. Le namespace temporaire
a été supprimé et le pod code-server est resté `Ready` après le test.
