# Politique de sécurité

## Versions prises en charge

Seule la dernière version publiée du dépôt reçoit des correctifs de sécurité. La branche principale est une branche de développement : elle peut contenir des changements non encore qualifiés. Les anciennes versions ne sont pas maintenues, sauf annonce explicite dans leurs notes de publication.

Ce projet reste une architecture de référence. Son profil local utilise notamment un NodePort sans TLS, un stockage mono-nœud et un secret Kubernetes classique ; ces choix ne constituent pas une configuration de production publique. Les contrôles requis avant une exposition publique sont décrits dans [docs/production.md](docs/production.md).

## Signaler une vulnérabilité

Ne publiez pas de vulnérabilité, de secret, de kubeconfig ni de procédure d’exploitation dans une issue publique.

Utilisez en priorité le formulaire **Report a vulnerability** de l’onglet Security du dépôt, lorsque les GitHub Private Vulnerability Reporting sont activés. À défaut, contactez le mainteneur par le canal privé indiqué sur la page du projet ou de l’organisation qui distribue ce dépôt.

Le signalement devrait contenir :

- la version ou la révision concernée ;
- le composant et la configuration touchés ;
- l’impact attendu et les prérequis d’exploitation ;
- une reproduction minimale, sans données réelles ni secrets ;
- les pistes de correction ou de mitigation déjà testées.

Une réception est normalement confirmée sous cinq jours ouvrés. Le mainteneur coordonne ensuite la reproduction, la correction, les crédits et la publication. Aucun délai de correction fixe n’est garanti : il dépend de l’impact, des dépendances amont et de la disponibilité d’une mitigation sûre.

## Périmètre sensible

Sont notamment considérés comme sensibles :

- une sortie de la micro-VM Kata ou un accès au nœud K3s ;
- un élargissement des capabilities au-delà de `SETUID|SETGID` ;
- un contournement de l’UID 1000, du mode Podman rootless ou du mapping subuid/subgid ;
- un binaire setuid supplémentaire ou une altération des helpers Shadow ;
- un montage `hostPath`, un périphérique hôte, un socket de runtime ou un namespace hôte exposé au pod ;
- une fuite du mot de passe code-server, d’un Secret, d’un kubeconfig ou de données du PVC ;
- une rupture de la vérification de digest ou de checksum de la chaîne de construction.

Les vulnérabilités propres à Kubernetes, Kata Containers, code-server, Podman, Ubuntu ou Shadow doivent aussi être signalées au projet amont concerné. Un problème d’intégration ou une configuration dangereuse propre à ce dépôt reste toutefois dans le périmètre de cette politique.

## Données à retirer avant de partager des journaux

Supprimez au minimum les mots de passe, tokens, certificats, kubeconfigs, adresses publiques, noms de compte, contenus du workspace et chemins locaux identifiants. Les commandes de diagnostic ne doivent jamais joindre le contenu d’un Secret à une issue ou à une trace CI.
