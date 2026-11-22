# Contribuer

Merci de contribuer à cet environnement code-server, Podman rootless et Kata Containers. Le dépôt privilégie des changements petits, reproductibles et accompagnés de preuves.

## Avant de commencer

- Ouvrez une issue ou une discussion avant une évolution d’architecture importante.
- Ne joignez jamais `.state/`, un kubeconfig, un Secret, un mot de passe ou des données du workspace.
- Séparez autant que possible les mises à jour de dépendances des changements fonctionnels.
- Conservez les checksums, digests et versions épinglées. Une mise à jour ne doit pas remplacer un pin par `latest`.

Le parcours principal s’exécute sous WSL 2 avec Bash. PowerShell reste le chemin de bootstrap et de compatibilité Windows.

## Invariants de sécurité

Une contribution ne doit pas affaiblir silencieusement les propriétés suivantes :

- un seul conteneur applicatif dans le pod ;
- une RuntimeClass Kata explicitement sélectionnée ;
- code-server et Podman sous l’UID/GID 1000, avec Podman rootless ;
- système racine en lecture seule et aucun `hostPath`, socket de runtime, périphérique ou namespace hôte ;
- `drop: [ALL]`, puis uniquement `SETUID` et `SETGID` dans le bounding set ;
- seuls `newuidmap` et `newgidmap` sont setuid ;
- aucun compte de service monté automatiquement ;
- graphroot Podman sur le tmpfs et données durables sur le PVC.

Une modification de Shadow, des helpers uidmap, des capabilities, de seccomp, des namespaces ou du stockage doit expliquer le modèle de menace et fournir les preuves live correspondantes.

## Validation locale

Sous WSL/Linux :

```bash
make check
```

Sous PowerShell :

```powershell
pwsh -NoProfile -File .\tests\Test-Static.ps1
```

Avec Helm disponible, ajoutez `-RenderHelmChart`. Pour une modification qui touche l’image, Kubernetes ou Kata, exécutez également sur un cluster de test :

```bash
make deploy
make verify
make benchmark
```

N’utilisez pas un cluster public ou contenant des données uniques pour ces essais. La procédure complète de montée de version et de rollback se trouve dans [docs/upgrading.md](docs/upgrading.md).

## Contenu d’une proposition de changement

La description devrait préciser :

- le problème et le résultat attendu ;
- les fichiers et composants concernés ;
- les conséquences de sécurité, persistance et performance ;
- les tests exécutés et leurs résultats ;
- le plan de migration et de rollback lorsqu’un état durable est touché.

Mettez à jour `CHANGELOG.md` dans la section `Unreleased` pour tout changement visible par un utilisateur ou un opérateur. Les rapports de benchmark doivent mentionner le matériel, les versions, le protocole, le nombre d’itérations et les limites de comparaison.

## Style

- Les scripts Bash utilisent `set -Eeuo pipefail` lorsqu’il est adapté.
- Les scripts PowerShell utilisent le mode strict et arrêtent sur erreur.
- Les commandes destructives valident leurs cibles et exigent une intention explicite.
- Les documents opérationnels restent orientés WSL/Linux et signalent clairement les étapes Windows obligatoires.
- Les commentaires décrivent la raison d’un choix non évident, pas simplement la syntaxe.
