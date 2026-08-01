# Strata

Analyseur d'espace disque pour macOS. Open source, natif, rapide.

> État : moteur de scan terminé et validé, interface en cours (lot 2/7).

## Le moteur

`DiskCore` est un package Swift sans dépendance, utilisable seul.

- Énumération via `getattrlistbulk(2)` — des centaines d'entrées par appel
  système au lieu d'un `stat()` par fichier.
- Arbre stocké en tableaux parallèles indexés par `Int32`, pas en graphe
  d'objets : pas de trafic ARC, enfants contigus, remontée des tailles en une
  passe linéaire.
- Sémantique alignée sur `du(1)` : taille allouée sur disque (donc correcte
  pour les fichiers creux et la compression APFS), liens durs comptés une
  seule fois, ni liens symboliques ni frontières de volume franchis.

Mesuré sur un MacBook 10 cœurs : **1,35 million de fichiers en 16 s** (5 M/min).
Totaux vérifiés identiques à `du -sk` sur quatre arborescences réelles.

```sh
cd DiskCore
swift run -c release diskscan ~/Library --depth 2
swift test
```

## Limites connues

- Les **clones APFS** (fichiers partageant des blocs) sont comptés plusieurs
  fois. Les détecter demanderait un appel par bloc ; DaisyDisk a la même limite.
- Sans **accès complet au disque**, certains dossiers restent illisibles. Ils
  sont signalés plutôt que silencieusement omis.
- Dans un dossier replié (`node_modules`…), les liens durs sont dédupliqués au
  sein du sous-arbre, pas rétroactivement contre le reste du scan.

## Licence

MIT.
