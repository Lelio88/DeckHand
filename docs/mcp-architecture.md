# Assistant IA : OAuth, consentement et serveur MCP — DeckHand

Annexe de [`architecture.md`](./architecture.md). Décrit comment un assistant IA
(claude.ai, Claude Code, Cursor…) obtient le droit d'agir sur la collection d'un
utilisateur, et ce qui borne ce droit.

## Vue d'ensemble

```
assistant ──OAuth 2.1──► Supabase Auth  (serveur OAuth, inscription dynamique des clients)
    │                        └─ consentement : deckhand.heianenterprise.com/oauth-consent.html
    └──MCP (HTTP)──► serveur MCP ──jeton de l'utilisateur──► fonctions SQL existantes (RLS)
```

**Supabase Auth est le serveur d'autorisation**, DeckHand n'en écrit aucun.
Activé par `api/push_auth_config.py` (production) et `supabase/config.toml`
(pile locale) : serveur OAuth 2.1, inscription dynamique des clients, chemin
d'autorisation `/oauth-consent.html` sous le Site URL. Un assistant découvre les
adresses (`/.well-known/oauth-authorization-server`), s'inscrit, envoie
l'utilisateur sur la page de consentement, puis échange le code contre un jeton.

**Ce jeton est un jeton d'utilisateur ordinaire** — `role` `authenticated`, `sub`
de l'utilisateur — plus une revendication `client_id`. `auth.uid()` le lit comme
celui de l'application : toutes les fonctions et politiques existantes
s'appliquent sans changement, chacun ne voit que sa collection.

## Le parcours

1. L'assistant appelle le serveur MCP sans jeton, reçoit un 401 qui désigne
   Supabase Auth, s'y inscrit (une fois) et lance l'autorisation.
2. Supabase Auth valide la demande (client, adresse de retour, PKCE) et
   renvoie le navigateur sur `oauth-consent.html?authorization_id=…`.
3. La page connecte l'utilisateur, lit la demande
   (`GET /auth/v1/oauth/authorizations/{id}`), montre **qui demande et où
   l'autorisation sera remise**, puis transmet la décision
   (`POST …/{id}/consent`, `approve` ou `deny`).
4. Supabase Auth rend l'adresse de retour de l'assistant, munie du code ;
   l'assistant l'échange contre ses jetons.

Un consentement déjà donné au même assistant fait répondre l'étape 3
directement par l'adresse de retour : la page y va sans redemander.

## La page de consentement

`app/web/oauth-consent.html` + `oauth-consent.js` : un fichier statique, pas une
route de l'application, parce que le build web publié ne sait que lire des
classeurs (`DECKHAND_PUBLIC_ONLY`). **Jumelle de la page de suppression de
compte** pour la connexion : appels REST sans bibliothèque, mot de passe ou
jeton Google, jetons en mémoire seulement, adresse et clé injectées par
`pages.yml`, refus de tourner dans un cadre, messages neutres. Ce qu'elle a en
propre :

- **l'adresse de retour est affichée** avant l'accord. L'inscription des
  clients étant ouverte, c'est ce qui permet de reconnaître une application qui
  se ferait passer pour un assistant connu ; une adresse en `javascript:`,
  `data:` ou `vbscript:` n'est jamais suivie ;
- **la déconnexion est locale** (`/logout?scope=local`) : sans paramètre,
  GoTrue fermerait toutes les sessions du compte, téléphone compris ;
- un compte Google sans compte DeckHand, créé par la connexion même, est
  supprimé aussitôt ;
- hors index (`noindex`) et hors `sitemap.xml` : c'est une étape, pas une page.

Supabase n'accepte la lecture et la décision que depuis l'**origine du Site
URL** : la page ne fonctionne que servie à `deckhand.heianenterprise.com` (ou
`127.0.0.1:8099` sur la pile locale).

## La garde : un assistant agit sur les cartes, jamais sur le compte

Les *scopes* OAuth ne règlent que les informations d'identité, pas l'accès aux
données. Et rien n'oblige le détenteur d'un jeton à passer par le serveur MCP :
PostgREST l'accepte tel quel. La migration `20261002100000_garde_assistant.sql`
dit donc, en base, ce qu'un jeton portant un `client_id` ne fait pas, quel que
soit le chemin :

| Geste | Jeton de l'application | Jeton d'assistant |
|---|---|---|
| Lire la collection, ajouter ou retirer des cartes | oui | oui |
| Supprimer le compte (`delete_my_account`) | oui | **refusé** (42501) |
| Modifier ou effacer la ligne `collections` — publier, dépublier, renommer | oui | **refusé** (zéro ligne touchée) |
| Créer sa collection au premier ajout (`ensure_my_collection`) | oui | oui |

Déjà fermés à tout jeton `authenticated`, donc à l'assistant : la clé du calque,
l'écriture du journal, les écritures du calque. Mot de passe et adresse
relèvent de GoTrue, qui exige une réidentification pour le premier et une
double confirmation pour la seconde.

Vérifié dans les deux sens, sous le rôle `authenticated`, par
`supabase/tests/assistant.test.sql` : ce que l'assistant fait passe, ce qu'il
ne fait pas lui est refusé, et l'application garde tous ses gestes.

## Révoquer

L'utilisateur voit et retire les accès accordés (`GET` / `DELETE
/auth/v1/user/oauth/grants`). Révoquer un accès invalide ses jetons de
rafraîchissement ; le jeton d'accès en cours expire seul (une heure).
