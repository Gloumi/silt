# Analyses sauvegardées — design

Date : 2026-10-17 · Statut : validé en discussion, spec à relire

## Intention

Au lancement, Silt rouvre la dernière analyse au lieu de repartir de « Prêt à
analyser ». Une analyse du disque entier prend plusieurs minutes. La refaire à
chaque lancement pour retrouver des chiffres qu'on avait déjà, c'est la friction
que ce chantier supprime.

Le complément direct du partage des analyses entre emplacements (livré juste
avant) : une analyse de `/` sauvegardée couvre aussi Téléchargements, Documents,
etc. au lancement suivant, sans rien rescanner.

La contrepartie : des chiffres sauvegardés vieillissent. Leur âge doit toujours
se voir, et au-delà d'un seuil Silt refuse de les montrer.

### Objectifs

- Toute analyse terminée (non annulée) survit à la fermeture de l'app.
- Au lancement, l'emplacement affiché en dernier revient avec son analyse, en
  moins d'une seconde pour un disque entier, sans bloquer l'interface.
- L'âge d'une analyse reste visible en permanence. Passé un jour, il est
  signalé comme ancien.
- Au-delà d'un seuil réglable (7 jours par défaut), une analyse n'est plus
  affichée : l'emplacement repasse en « Prêt à analyser », en indiquant la date
  de la dernière analyse.
- Les noms de fichiers sauvegardés ne sont pas lisibles par les autres apps.

### Non-objectifs

- Détecter ce qui a changé depuis l'analyse (FSEvents) ou ne rescanner que les
  dossiers modifiés. C'est l'étape suivante logique, mais pas celle-ci.
- Sauvegarder une analyse annulée (partielle), pour la même raison qu'elle
  n'entre pas dans le cache mémoire : la resservir comme complète sous-estimerait
  l'occupation.
- Restaurer l'état de navigation (dossier ouvert, sélection, recherche). On
  rouvre l'emplacement à sa racine.
- Annuler après relancement une suppression faite pendant une session
  précédente. Le bandeau d'annulation reste propre à la session.
- Invalider une analyse quand les réglages d'analyse ont changé (paquets,
  dossiers de dépendances). Le réglage dit déjà que l'arbre affiché garde sa
  forme jusqu'à la prochaine analyse, et ça reste vrai.

### Anti-objectifs (échec même si « ça marche »)

- Un lancement sensiblement plus lent, ou une fenêtre qui gèle pendant le
  chargement.
- Une boîte de dialogue au lancement (trousseau ou autre).
- Des chiffres anciens affichés sans que l'âge se voie.
- Un fichier contenant en clair les noms de tous les fichiers du disque, y
  compris ceux des zones protégées par l'accès complet au disque (Mail,
  Messages…). Ce fichier contournerait la protection de macOS au profit de
  n'importe quelle app.

## Contexte technique

- L'arbre (`NodeStore`, `DiskCore/Sources/DiskCore/Model/NodeStore.swift`) est
  stocké en tableaux parallèles indexés par nœud, avec un blob de noms. Rien à
  convertir : les sérialiser revient à écrire ces tableaux bout à bout.
- `ScanModel` (`App/Model/ScanModel.swift`) garde l'arbre à l'écran (`result`,
  `scannedAt`, `treeRootPath`) et un cache LRU de 3 arbres
  (`cache: [(path, CachedScan)]`, `cacheLimit`). L'arbre de `/` est évincé en
  dernier. `tree(holding:)` cherche dans l'arbre à l'écran et dans le cache
  l'arbre le plus récent qui contient un chemin. C'est le point d'entrée par
  lequel les analyses sauvegardées doivent devenir visibles.
- Une suppression modifie l'arbre sur place (`markDeleted` : drapeau `.deleted`
  sur le nœud, totaux des ancêtres crédités).
- Au lancement, `SidebarView` sélectionne le volume de démarrage sans scanner
  (`model.select(path:name:)`).
- Les builds publiées sont signées ad hoc (voir
  `2026-10-14-update-check-design.md`) : le cdhash change à chaque version, et
  à chaque build Debug.

## Ce qui a été décidé

### Ce qu'on sauvegarde, et quand

- On sauvegarde chaque arbre terminé, celui à l'écran et ceux du cache. Le
  disque suit la mémoire : au plus `cacheLimit + 1` fichiers. Un arbre évincé du
  cache voit son fichier supprimé. Un rescan remplace le fichier de sa racine.
- On écrit à la fin d'une analyse, et après une suppression, une annulation ou
  une restauration depuis la corbeille, avec un délai de regroupement de
  quelques secondes pour ne pas réécrire 100 Mo à chaque clic. L'écriture se
  fait hors du thread principal, dans un fichier temporaire renommé ensuite
  (jamais de fichier à moitié écrit).
- Contenu : les tableaux du `NodeStore`, drapeaux `.deleted` compris (un nœud
  supprimé reste masqué au relancement), les métadonnées de `ScanResult`
  (`unreadablePaths`, `filesSeen`, `directoriesSeen`, `duration`), le chemin
  racine demandé, `scannedAt`, et un numéro de version du format. Un fichier
  d'une autre version du format est ignoré et supprimé.
- On retient aussi le dernier emplacement sélectionné (chemin + nom affiché),
  pour le resélectionner au lancement à la place du volume de démarrage.

### Où, et comment c'est protégé

- Emplacement : `~/Library/Caches/<bundle id>/Scans/`. C'est régénérable, donc
  un cache au sens de macOS.
- Compression LZFSE, puis chiffrement AES-GCM (CryptoKit). La clé de 256 bits
  est créée au premier enregistrement et rangée dans le trousseau (mot de passe
  générique, service = bundle id).
- **Jamais de dialogue du trousseau.** La lecture de la clé se fait sans
  interface (`kSecUseAuthenticationUI` = échec silencieux). Avec la signature
  ad hoc, une nouvelle version (ou un nouveau build Debug) ne peut pas lire la
  clé de la précédente. Dans ce cas, Silt crée une nouvelle clé sous un autre
  nom de compte et supprime les analyses qu'il ne peut plus déchiffrer.
  Conséquence assumée : après une mise à jour, la première analyse est à
  refaire. Les mises à jour sont rares, et une analyse de plus d'une semaine
  serait de toute façon refusée.
- **Debug n'est pas chiffré** (décision de Renan). Chaque build Debug a un
  nouveau cdhash : chiffrer laisserait un élément orphelin dans le trousseau à
  chaque rebuild, et perdrait les analyses à chaque rebuild, ce qui rend la
  fonction impossible à essayer en développement. Le build Debug écrit donc la
  même chose en clair (compressé), dans un dossier distinct (`Scans-debug/`)
  pour qu'un build ne tente jamais de lire les fichiers de l'autre. Les versions
  publiées chiffrent, avec un élément orphelin par mise à jour, ce qui est
  accepté.
- Tout fichier illisible (clé absente, déchiffrement ou décodage qui échoue,
  incohérence des tableaux) est supprimé sans bruit, et l'emplacement se
  comporte comme jamais analysé.

### Au lancement

- Les analyses sauvegardées sont déchiffrées et décodées en tâche de fond, puis
  versées dans le cache de `ScanModel`. Tant que ce n'est pas fini, rien ne
  bloque : l'emplacement affiche « Prêt à analyser ».
- Dès qu'elles sont chargées, si rien n'est à l'écran et que l'emplacement
  sélectionné est couvert par l'une d'elles (via `tree(holding:)`), il s'affiche
  directement. Si l'utilisateur a lancé un scan entre-temps, on ne touche à rien.
- Les fichiers au-delà du seuil d'ancienneté ne sont pas chargés et sont
  supprimés.

### Ancienneté

- La barre d'état affiche déjà « analysé il y a … ». On garde cet affichage.
- Au-delà de 24 h, la mention passe en orange avec le mot « ancienne », et une
  info-bulle invite à actualiser.
- **Seuil** : réglage « Ne plus afficher une analyse après » dans Réglages ›
  Analyse. Valeurs proposées : 1, 3, 7 (défaut), 14, 30 jours. Le seuil vaut
  aussi pour les arbres en mémoire : si l'app reste ouverte une semaine, une
  analyse dépassée n'est plus servie par `tree(holding:)`.
- Un emplacement dont la seule analyse a dépassé le seuil affiche l'écran
  « Prêt à analyser » avec une ligne en plus : « Dernière analyse il y a 9 jours,
  trop ancienne pour être affichée. » Pour ça, il faut garder la date des
  analyses refusées (dans les préférences, par racine, sans les noms de
  fichiers).
- *(Choix de Claude)* Un emplacement couvert seulement par l'analyse expirée
  d'un dossier parent affiche aussi cette ligne, en nommant le parent :
  « La dernière analyse de « Macintosh HD » date de 9 jours, trop ancienne pour
  être affichée. » La recherche se fait par préfixe de chemin sur les racines
  retenues. Sans l'arbre, on ne sait pas si le parent est vraiment entré dans le
  dossier, mais la phrase reste vraie : elle parle de l'analyse du parent.
- L'arbre à l'écran qui franchit le seuil pendant qu'on le regarde n'est pas
  retiré sous les yeux de l'utilisateur. Le seuil joue à la prochaine
  sélection.

### Suppressions et restaurations dans tous les arbres *(choix de Claude)*

Aujourd'hui, `markDeleted` ne touche que l'arbre à l'écran. Si `/` a été
analysé puis Téléchargements seul, un fichier supprimé depuis Téléchargements
reste compté dans l'arbre de `/`. En session, c'était un écart mineur. Sauvegardé
jusqu'à 7 jours, il gonflerait les totaux du disque. Donc :

- une suppression, et son annulation, s'appliquent à **chaque arbre en mémoire**
  (à l'écran et en cache) qui contient le chemin (`NodeStore.node(atPath:)`), et
  chaque arbre touché est réécrit ;
- une restauration depuis l'outil Corbeille (`restoreFromTrash`) remet le nœud
  en place dans chaque arbre qui le contient, avec `unmarkDeleted`, en
  **remesurant l'élément sur disque**. `markDeleted` a mis à zéro les totaux
  propres du nœud, et le registre de la corbeille ne garde que `bytes` : la
  taille réelle se relit avec `lstat` pour un fichier, `PathSize` pour un
  dossier. Sans ça, un élément restauré resterait masqué jusqu'au rescan, donc
  jusqu'à 7 jours une fois sauvegardé.

### Sécurité des suppressions

Une analyse vieille de plusieurs jours peut désigner, sous le même chemin, un
autre fichier que celui qu'elle a mesuré. Aujourd'hui, la suppression vérifie
seulement que le chemin existe. Désormais, à la construction du plan de
suppression (`requestDeletion`), chaque **fichier** est revérifié sur disque
(`lstat`) :

- s'il a disparu, il sort du plan, et la fiche dit qu'il n'existe plus ;
- si sa taille ou sa date de modification ne correspondent plus à l'arbre, il
  reste dans le plan avec une mise en garde (« … — modifié depuis l'analyse ») et
  le total affiché utilise sa taille actuelle.

Pour un dossier, on vérifie seulement qu'il existe encore et qu'il est toujours
un dossier : ses totaux sont cumulés, il n'y a rien de simple à comparer. Cette
vérification vaut pour toutes les suppressions, analyse sauvegardée ou non.

## Ce qui est laissé au builder

- Le format binaire exact (en-tête, ordre des tableaux, boutisme), et le
  découpage entre DiskCore et l'app. Seule contrainte : le codage et le décodage
  du `NodeStore` vivent dans DiskCore, parce que ses tableaux y sont
  `private(set)` et que c'est la seule cible testée.
- La forme du stockage de la clé (nom du compte, schéma de renouvellement), tant
  qu'aucun dialogue n'apparaît.
- La durée de regroupement des écritures.
- Le nommage des fichiers (un hash du chemin racine convient).
- La présentation exacte du badge « ancienne » et de la ligne « trop ancienne »,
  dans le style de la barre d'état et de l'écran vide existants.

## Tests attendus

Dans DiskCore :

- Aller-retour encodage → décodage d'un arbre scanné : tableaux identiques,
  `path(of:)` et `node(atPath:)` donnent les mêmes réponses, drapeaux `.deleted`
  conservés.
- Un fichier tronqué, modifié ou chiffré avec une autre clé est rejeté (`nil`),
  sans plantage.
- Un fichier d'une autre version de format est rejeté.

Dans l'app, à la main : analyser `/`, quitter, relancer → l'analyse revient tout
de suite avec son âge, et Téléchargements s'ouvre sans scan. Changer le seuil à
1 jour avec une analyse plus vieille → l'emplacement repasse en « Prêt à
analyser » avec la date.
