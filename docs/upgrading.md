# Mettre à jour l’environnement

## Principe

Une mise à jour est une reconstruction qualifiée, pas une modification manuelle du pod actif. Ne mettez pas à jour simultanément Ubuntu, Podman, Shadow, code-server, K3s et Kata : séparez les changements afin qu’une régression puisse être attribuée et annulée.

Les versions validées sont déclarées dans `versions.psd1`. Certains fichiers conservent encore des valeurs littérales pour permettre une utilisation autonome ; `make versions-check` vérifie leur cohérence. Tant que cette duplication existe, une mise à jour doit contrôler au minimum :

- `container/Dockerfile` pour Ubuntu, code-server et Shadow ;
- `k8s/base/deployment.yaml` pour le tag de l’image workspace ;
- `scripts/linux/Install-K3sKata.sh` pour K3s, Helm et Kata ;
- l’image publiée par digest dans l’overlay de production.

## Avant la modification

1. Créez une branche dédiée et vérifiez que l’arbre Git ne contient aucun changement sans rapport.
2. Relevez les versions en service, le digest de l’image, les noyaux hôte/invité et la configuration de la RuntimeClass.
3. Sauvegardez les PVC, puis prouvez qu’une restauration est lisible dans un environnement isolé.
4. Prenez un snapshot ou créez un clone de la VM/du pool de nœuds. Une sauvegarde du PVC ne remplace pas une sauvegarde du plan de contrôle.
5. Consultez les notes de publication et incompatibilités des versions intermédiaires, pas seulement de la cible finale.
6. Fixez des seuils de régression pour démarrage, build Podman, I/O, mémoire et disponibilité.

Ne placez pas les sauvegardes, kubeconfigs ou rapports contenant des secrets dans le dépôt.

## Mettre à jour les pins

Modifiez `versions.psd1`, puis reportez les valeurs littérales nécessaires. Pour chaque artefact :

- récupérez la version depuis la publication officielle ;
- calculez ou vérifiez le SHA-256 depuis une source indépendante de l’archive lorsque l’amont le permet ;
- conservez le tag lisible et le digest de l’image ;
- n’utilisez jamais `latest` ;
- donnez à l’image workspace un tag unique, idéalement complété par son digest au déploiement.

Les paquets APT issus d’une même base peuvent évoluer après `apt-get update`. Une publication reproductible devrait employer un snapshot de dépôt ou, au minimum, conserver le SBOM et la liste exacte des paquets du build qualifié.

## Validation statique

Sous WSL/Linux :

```bash
make release-check
```

Sous PowerShell :

```powershell
pwsh -NoProfile -File .\tests\Test-Static.ps1 -RenderHelmChart
```

La CI exécute ces deux chemins sans identifiants et sans accès au cluster. Elle ne remplace pas les preuves live.

## Qualification isolée

Construisez et importez la nouvelle image dans une VM clonée ou un pool canary. N’écrasez pas l’unique tag de l’image en service : l’ancienne image et son digest doivent rester disponibles pendant toute la fenêtre de retour arrière.

Exécutez ensuite :

```bash
make doctor
make deploy
make verify
make benchmark BENCHMARK_ITERATIONS=30
```

Vérifiez aussi un scénario utilisateur réel : clone Git, installation de dépendances, compilation, redémarrage du pod et lecture des données persistantes. Comparez les résultats au même matériel et au même protocole que la version précédente.

## Portes propres aux composants

### Ubuntu, Podman et crun

- `podman info` doit conserver `rootless=true` et le driver OverlayFS attendu.
- Le graphroot et le runroot doivent rester sous `/tmp` sans `mount_program` FUSE inattendu.
- Le mapping doit contenir l’UID 0 intérieur vers 1000, puis la plage subuid/subgid.
- Un build et une exécution avec `USER 2000` doivent réussir.
- Les namespaces PID et réseau réellement employés doivent correspondre au modèle de menace documenté.

### Shadow et les helpers uidmap

- La configuration doit toujours produire `HAVE_SYS_CAPABILITY_H=1`.
- Seuls `newuidmap` et `newgidmap` peuvent être setuid, en `4755 root:root`.
- Le processus code-server doit conserver des jeux effectifs, permis, héritables et ambiants nuls.
- Le bounding set doit rester exactement `SETUID|SETGID`.
- Rejouez la preuve multi-UID ; une simple exécution mono-UID ne valide pas la recompilation.

Un changement de Shadow ne doit jamais être accepté uniquement parce que l’image compile.

### K3s, containerd et Kata

- La RuntimeClass et le handler containerd doivent exister après installation.
- Le noyau du pod doit être distinct du noyau du nœud.
- `privileged_without_host_devices=true` doit rester actif comme défense en profondeur.
- Testez les volumes, les probes, le NodePort de laboratoire et la suppression propre de la micro-VM.
- Une évolution de virtiofs, du driver bloc ou du noyau invité impose un benchmark stockage séparé.

Ne tentez pas de rétrograder K3s ou Kata en place sans procédure amont explicitement supportée. Préférez reconstruire un nœud depuis le snapshot ou la version précédente.

### code-server

- `/healthz` doit répondre avant ouverture du trafic.
- Le workspace, les extensions et les réglages existants doivent rester lisibles.
- Vérifiez l’authentification, l’ouverture d’un terminal et le lancement de Podman depuis celui-ci.
- Consultez les migrations de données et incompatibilités d’extensions annoncées par l’amont.

## Déploiement progressif

1. Déployez la version sur le canary avec un PVC de test restauré.
2. Observez les erreurs, la mémoire, l’I/O et les temps de démarrage pendant une période définie.
3. Sauvegardez de nouveau les données immédiatement avant la bascule principale.
4. Déployez par petits lots de workspaces ou de nœuds.
5. Conservez l’ancienne image, la configuration Kata et le snapshot pendant la période de validation.
6. Enregistrez les versions, digests, résultats de tests et écarts acceptés dans les notes de publication.

## Retour arrière

Pour une modification applicative sans migration de données, redéployez l’ancien digest d’image et l’ancien manifeste, puis relancez toutes les vérifications. `kubectl rollout undo` n’est fiable que si la révision précédente référence encore une image immuable disponible.

Pour K3s, Kata, le noyau invité ou une migration de stockage, retirez le nœud ou pool défectueux et restaurez le snapshot/la configuration précédente. Ne restaurez un PVC que si la nouvelle version a modifié son format ou ses données ; une restauration écrase des changements utilisateurs et exige une décision opérateur explicite.

Après le rollback, vérifiez code-server, Podman rootless, le mapping multi-UID, le stockage et l’accès aux données avant de rouvrir le trafic.

## Dossier de publication

Une publication devrait conserver :

- le diff de `versions.psd1` ;
- les digests de toutes les images ;
- le SBOM et les résultats de scan ;
- les versions K3s, containerd, Kata, QEMU, noyaux hôte/invité et Podman ;
- les résultats statiques, live, restauration et benchmark ;
- les exceptions de sécurité et leur date d’expiration ;
- le plan de rollback effectivement testé ;
- les entrées correspondantes de `CHANGELOG.md`.
