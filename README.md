# Les Caméliats – Suivi technique

Application de signalement et de suivi technique de la résidence Les Caméliats.
Site statique (un fichier `index.html`) branché sur une base Supabase partagée.

## Contenu

| Fichier | Rôle |
|---|---|
| `index.html` | L'application (interface, plans cliquables, imports, export CSV). |
| `config.js` | Adresse du projet Supabase et clé publique. Aucun secret. |
| `vendor/supabase.js` | Bibliothèque cliente Supabase (supabase-js 2.119.0, empaquetée). |
| `supabase/schema.sql` | Tables, droits par profil et fonctions. À exécuter une seule fois. |
| `supabase/tests/` | Tests des règles d'accès sur un Postgres local. |

Les plans de l'immeuble ne sont pas dans ce dépôt : ils sont rangés dans un
espace de stockage privé de Supabase et ne sont servis qu'aux utilisateurs connectés.

## Mise en service (une seule fois)

1. **Base de données.** Dans Supabase, ouvrir *SQL Editor*, coller tout le contenu de
   `supabase/schema.sql`, cliquer sur *Run*.
2. **Adresse du site.** Dans *Authentication > URL Configuration*, mettre l'adresse du site
   (par exemple `https://<compte>.github.io/<depot>/`) dans *Site URL* et dans *Redirect URLs*.
3. **Envoi des e-mails.** Le service d'e-mail intégré de Supabase n'écrit qu'aux membres de
   l'équipe du projet. Pour que les voisins reçoivent leur lien, brancher un service d'envoi
   dans *Authentication > Emails > SMTP Settings* (par exemple Brevo, offre gratuite).
4. **Modèle d'e-mail (facultatif).** Dans *Authentication > Emails > Magic Link*, ajouter
   `Votre code : {{ .Token }}` pour que le code à saisir figure aussi dans le message.
5. **Réglages.** Renseigner `url`, `key` et `contact` dans `config.js`.
6. **Premier compte.** Le tout premier inscrit devient automatiquement membre du Conseil
   syndical. Se connecter soi-même aussitôt après l'étape 1.
7. **Plans.** Dans l'application : *Administration > Plans*, sélectionner les 9 images
   (noms commençant par `01` à `09`).
8. **Code d'invitation.** Il est tiré au hasard à l'installation. Le lire ou le changer dans
   *Administration*, puis le communiquer aux résidents.

## Droits appliqués par la base

| Profil | Voit | Peut |
|---|---|---|
| Conseil syndical | tout, y compris l'auteur de chaque signalement | tout, y compris valider les comptes et supprimer |
| Syndic | tout, y compris l'auteur | déclarer, importer, exporter, statut, ordre de service |
| Résident | tous les signalements, sans l'auteur (sauf les siens). Pour le logement d'un autre : catégorie, gravité, statut, date et étage seulement | déclarer (en privatif : son logement seulement) |
| Prestataire | les signalements de sa spécialité, sans l'auteur | changer le statut |
| En attente | rien (écran flouté) | rien |

Ces règles sont dans `schema.sql` (row level security). L'interface les reflète, mais c'est
la base qui les impose : un navigateur ne reçoit jamais un signalement masqué.

## Mise à jour des règles de visibilité (11/11/2026)

Sur une base déjà installée, ne pas relancer `schema.sql` : coller le contenu de
`supabase/patches/2026-11-11_visibilite.sql` dans *SQL Editor*, puis *Run* (une seule fois, sans danger si répété).
Le site lit désormais les signalements par la vue `tickets_feed`, qui masque l'auteur et le détail des logements des autres.

## Corbeille et journal (11/11/2026)

Deuxième patch, à lancer après le premier : `supabase/patches/2026-11-11_corbeille_journal.sql`
(*SQL Editor*, *Run*, une seule fois ; sans danger si répété).
« Supprimer » place l'incident dans une corbeille que seul le Conseil syndical voit
(bouton *Historique*) : il peut le restaurer ou le supprimer définitivement. Un journal
(`ticket_log`) garde les créations, changements de statut, ordres de service, suppressions,
restaurations et suppressions définitives. Le titre est effacé du journal à la suppression définitive.

## Tester les règles en local

```sh
psql -f supabase/tests/00_faux_supabase_local.sql      # crée la base ftest et un faux schéma auth
psql -d ftest -v ON_ERROR_STOP=1 -f supabase/schema.sql
psql -d ftest -f supabase/tests/01_regles_acces.sql    # règles d'origine (lecture des signalements : voir 02)
# (pour 02 et 03 : relancer d'abord les deux premières commandes, sur une base neuve)
psql -d ftest -f supabase/tests/02_visibilite.sql      # visibilité du 11/11/2026 ; les ERROR affichées sont les refus attendus
psql -d ftest -f supabase/tests/03_corbeille_journal.sql  # corbeille, restauration, journal
```

## Import sans doublons (12/11/2026)

Patch : `supabase/patches/2026-11-12_import_doublons.sql` (à lancer une fois dans le SQL Editor, déjà inclus dans `schema.sql`).

* Chaque message importé reçoit une empreinte (`import_key`, unique). Réimporter le même texte n'ajoute rien :
  les messages déjà importés sont repérés, y compris ceux partis à la corbeille.
* Les incidents qui ressemblent à un incident déjà ouvert (même endroit, même catégorie) sont décochés par défaut.
* Un message de suivi (« réparé », « le technicien passe demain ») met à jour l'incident précédent au lieu d'en créer un nouveau.
* L'empreinte n'est lisible que par le Conseil syndical et le syndic (fonction `known_imports`). Test : `supabase/tests/04_import_doublons.sql`.
