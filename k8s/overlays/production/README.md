# Overlay de production

Cet overlay est volontairement inapplicable sans personnalisation : le registre
et le nom DNS utilisent le domaine réservé `example.invalid`, et le digest de
l'image est composé de zéros. Cette valeur empêche un déploiement accidentel
d'une image mutable ou locale.

Avant le rendu :

1. remplacez `newName` et `digest` dans `kustomization.yaml` par l'image publiée
   et qualifiée par la CI ;
2. remplacez `code-server.example.invalid` et, si nécessaire,
   `code-server-tls` dans `ingress.yaml` ;
3. créez le Secret `code-server-auth` depuis votre gestionnaire de secrets ;
4. choisissez une StorageClass persistante compatible avec Kata et ajoutez un
   patch `storageClassName` au PVC si la classe par défaut ne convient pas ;
5. étiquetez le namespace de l'Ingress Controller :

   ```bash
   kubectl label namespace ingress-nginx code-server-ingress=allowed
   ```

Validez ensuite côté serveur avant application :

```bash
kubectl kustomize k8s/overlays/production > /tmp/code-server-production.yaml
kubectl apply --server-side --dry-run=server \
  -f /tmp/code-server-production.yaml
```

Le Service reste en `ClusterIP`. Seul l'overlay local `kvm`/`mshv` rétablit le
NodePort de laboratoire. Ne stockez jamais le manifeste rendu s'il contient des
valeurs issues d'un gestionnaire de secrets.
