# Passage vers un environnement de production

## Statut

Ce dépôt est une architecture de référence validée dans un laboratoire local mono-nœud. Il démontre qu’un unique conteneur peut héberger code-server et Podman rootless dans une micro-VM Kata avec une enveloppe de capabilities minimale.

Les overlays locaux `kvm` et `mshv` rétablissent un NodePort sans TLS et ne doivent pas être exposés sur Internet. L’overlay [`k8s/overlays/production`](../k8s/overlays/production/README.md) conserve au contraire un Service `ClusterIP`, ajoute un Ingress TLS et une NetworkPolicy, et refuse implicitement de démarrer tant que son image par digest et son domaine réservé ne sont pas remplacés. Il reste un point de départ : le mot de passe code-server n’est pas une identité d’entreprise, le PVC `local-path` n’est ni répliqué ni sauvegardé et le pod partage ses namespaces PID et réseau avec les conteneurs Podman intérieurs.

## Utiliser l’overlay fourni

Avant application, remplacez l’image réservée `registry.example.invalid`, le digest nul, le domaine `code-server.example.invalid` et le Secret TLS. Créez `code-server-auth` depuis un gestionnaire externe, choisissez une StorageClass compatible avec les volumes Kata et étiquetez le namespace de l’Ingress Controller comme indiqué dans le README de l’overlay.

Rendez et validez toujours le résultat côté API avant mutation :

```bash
kubectl kustomize k8s/overlays/production > /tmp/code-server-production.yaml
kubectl apply --server-side --dry-run=server \
  -f /tmp/code-server-production.yaml
```

## Frontières de confiance

La micro-VM Kata est la frontière principale entre le code non fiable et le nœud Kubernetes. Podman rootless ajoute une seconde séparation à l’intérieur de l’invité. L’administrateur du cluster, l’image du workspace, la chaîne de construction, le runtime Kata, le VMM et le stockage restent dans la base de confiance.

Kata ne remplace pas les contrôles Kubernetes, l’authentification, les sauvegardes ou la sécurité de la chaîne logicielle. Un administrateur Kubernetes ou de l’hôte conserve le contrôle du workload.

## Invariants à conserver

Un profil dérivé doit préserver et vérifier :

- exactement un conteneur applicatif et une RuntimeClass Kata approuvée ;
- `runAsUser`, `runAsGroup` et groupe effectif à 1000 ;
- Podman `rootless=true` avec un mapping subuid/subgid non identité ;
- racine de l’image en lecture seule ;
- aucun `hostPath`, `hostPID`, `hostIPC`, `hostNetwork`, `hostPort`, socket de runtime ou périphérique hôte ;
- aucun token de service account monté automatiquement ;
- capabilities effectives nulles pour code-server, `drop: [ALL]` et bounding set limité à `SETUID|SETGID` ;
- uniquement `/usr/bin/newuidmap` et `/usr/bin/newgidmap` avec un bit setuid ;
- workspace persistant séparé du graphroot et des caches éphémères.

`allowPrivilegeEscalation=true` et le profil seccomp `Unconfined` sont actuellement nécessaires aux helpers uidmap et à Podman imbriqué sur cette pile. Ils constituent une dette de sécurité explicite. Toute réduction doit être prouvée par les tests multi-UID ; tout élargissement doit faire l’objet d’une revue de menace.

## Architecture minimale avant exposition publique

### Nœuds et runtime

- Utiliser des workers dédiés, durcis et labellisés pour Kata.
- Contrôler le placement par taints, tolerations et affinité de nœud.
- Maintenir séparément le noyau hôte, le noyau invité, QEMU, Kata, containerd et K3s/Kubernetes.
- Tester les RuntimeClass et configurations Kata sur un pool canary avant le pool principal.
- Définir des quotas CPU, mémoire, stockage éphémère et nombre de pods par utilisateur.

### Images et chaîne logicielle

- Publier l’image dans un registre privé ou maîtrisé ; ne pas utiliser `localhost/...`.
- Employer un tag unique par build et déployer par digest immuable.
- Produire un SBOM, scanner l’image et conserver les résultats avec la publication.
- Signer l’image et vérifier sa signature par une politique d’admission.
- Épingler les images de test et les sources téléchargées par digest ou checksum.
- Reconstruire régulièrement depuis une base corrigée plutôt que modifier un conteneur en cours d’exécution.

Le workflow GitHub Actions `Publish workspace image` fournit une base reproductible pour GHCR : il construit depuis les pins de `versions.psd1`, publie un tag de version et un tag lié au commit, puis affiche le digest avec SBOM et provenance OCI. Une organisation de production doit encore ajouter son scanner, sa signature et sa politique d’admission avant promotion.

### Identité, secrets et accès réseau

- Placer code-server derrière un Ingress ou une passerelle authentifiée avec TLS.
- Préférer une identité centralisée et une authentification multifacteur au mot de passe local.
- Désactiver le NodePort public ; limiter les flux par NetworkPolicy et pare-feu du nœud.
- Filtrer l’egress selon les registres, dépôts de paquets et services réellement nécessaires.
- Fournir les secrets depuis un gestionnaire externe, avec rotation et journalisation.
- Ne jamais stocker un mot de passe, token, certificat ou kubeconfig dans l’image ou le dépôt.

### Stockage

- Remplacer `local-path` par un CSI adapté aux exigences de disponibilité et de reprise.
- Utiliser un volume bloc persistant compatible Kata pour réduire le coût virtiofs sur les métadonnées.
- Activer snapshots, sauvegardes hors cluster, chiffrement au repos et tests de restauration.
- Définir de vrais quotas ; le PVC local du laboratoire ne constitue pas un quota bloc strict.
- Garder les caches et couches Podman séparés des données utilisateur. Leur perte doit être prévue et documentée.

Le stockage brut ne doit pas être formaté par le conteneur applicatif : cela exigerait des privilèges incompatibles avec le profil minimal. Le CSI et Kata doivent présenter un filesystem déjà monté dans l’invité.

### Observabilité et réponse

- Centraliser journaux Kubernetes, Kata, QEMU/virtiofsd et événements d’admission.
- Alerter sur les redémarrages, OOM, pression disque, échecs de sauvegarde et changements de RuntimeClass.
- Mesurer séparément le pod, la micro-VM et les conteneurs Podman intérieurs.
- Conserver une piste d’audit des accès administrateur et des changements de politique.
- Maintenir une procédure de révocation, d’isolement d’un workspace et de rotation des secrets.

## Isolation des utilisateurs

Un pod ne doit pas héberger les sessions de plusieurs utilisateurs non mutuellement fiables. Le modèle recommandé est un pod et un PVC par identité, avec namespace, quotas et politiques réseau adaptés. Les conteneurs Podman intérieurs partagent actuellement les namespaces PID et réseau du pod Kata ; ils peuvent donc observer la loopback et interagir avec les processus du même UID dans cette micro-VM.

## Disponibilité et reprise

Le Deployment utilise une réplique et une stratégie `Recreate`, ce qui implique une interruption pendant la mise à jour. Pour un environnement de développement interactif, la haute disponibilité porte surtout sur la capacité à recréer rapidement le pod et restaurer son PVC.

Définissez avant ouverture du service :

- les objectifs RPO et RTO ;
- la fréquence et la rétention des sauvegardes ;
- le propriétaire de la restauration ;
- un test périodique de restauration dans un namespace isolé ;
- un plan de reconstruction des nœuds Kata sans dépendre de leur disque local.

## Portes d’acceptation

Une version destinée à la production doit réussir au minimum :

1. `make release-check`, puis les validations PowerShell et CI ;
2. rendu de la charte Helm Kata épinglée ;
3. construction, SBOM, scan et signature de l’image ;
4. admission du manifeste de production et refus de variantes hostPath/privilégiées ;
5. vérification live complète dans le pool canary ;
6. preuve du noyau invité distinct et du mapping multi-UID rootless ;
7. test de build et d’exécution Podman avec un utilisateur intérieur non nul ;
8. benchmark comparé au seuil de régression accepté ;
9. sauvegarde puis restauration effective d’un PVC de test ;
10. test d’accès via TLS, identité centralisée et politiques réseau.

La procédure de changement, de qualification et de retour arrière est détaillée dans [upgrading.md](upgrading.md).
