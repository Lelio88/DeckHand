# Assistant IA : OAuth, consentement et serveur MCP — DeckHand

Annexe de [`architecture.md`](./architecture.md). Décrit comment un assistant IA
(claude.ai, Claude Code, Cursor…) obtient le droit d'agir sur la collection d'un
utilisateur, et ce qui borne ce droit.

## Vue d'ensemble

```
assistant ──OAuth 2.1──► Supabase Auth  (serveur OAuth, inscription dynamique des clients)
    │                        └─ consentement : deckhand.heianenterprise.com/oauth-consent.html
    └──MCP (HTTP)──► Edge Function supabase/functions/mcp
                         └─ jeton de l'utilisateur ──► fonctions SQL existantes (RLS)
```

**Adresse du connecteur** : `<SUPABASE_URL>/functions/v1/mcp` — à coller dans
claude.ai (Paramètres → Connecteurs) ou dans `claude mcp add --transport http
deckhand <url>`. L'application la montre, avec un bouton pour la copier, le
geste exact pour claude.ai et Claude Code, et la liste des accès accordés avec
leur bouton « Révoquer », dans *Compte → Assistant IA*
(`app/lib/src/features/account/presentation/assistant_screen.dart`).

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

- **seuls les assistants reconnus peuvent être autorisés**, à leur adresse de
  retour exacte, chemin compris (`RETOURS_RECONNUS`) — voir « Ce que le jeton
  permet au-delà des outils » ci-dessous. Une demande inconnue est refusée
  (`deny`) sans que son adresse soit suivie ; l'assistant est désigné par
  l'adresse vérifiée, le nom qu'il se donne n'étant montré que comme « se
  présente comme » ;
- **la déconnexion est locale** (`/logout?scope=local`) : sans paramètre,
  GoTrue fermerait toutes les sessions du compte, téléphone compris ;
- un compte Google sans compte DeckHand, créé par la connexion même, est
  supprimé aussitôt ;
- hors index (`noindex`) et hors `sitemap.xml` : c'est une étape, pas une page.

Supabase n'accepte la lecture et la décision que depuis l'**origine du Site
URL** : la page ne fonctionne que servie à `deckhand.heianenterprise.com` (ou
`127.0.0.1:8099` sur la pile locale).

### Les assistants reconnus

| Assistant | Adresse de retour |
|---|---|
| Claude (claude.ai, Desktop, mobile) | `https://claude.ai/api/mcp/auth_callback` (et `claude.com`) |
| ChatGPT | `https://chatgpt.com/connector_platform_oauth_redirect`, `…/connector/oauth/{id}` |
| VS Code | `https://vscode.dev/redirect` |
| Cursor | `cursor://anysphere.cursor-mcp/oauth/callback` |
| Un outil de la machine (Claude Code, Cursor, VS Code) | `http://localhost`, `127.0.0.1`, `[::1]`, tout port et tout chemin |

Une adresse sur la machine est sûre quel que soit son chemin : le code ne sort
pas de chez l'utilisateur. Ailleurs, le chemin compte — un domaine seul
laisserait passer une redirection ouverte de ce domaine. Ajouter un assistant,
c'est une ligne de plus, avec son adresse exacte relevée dans sa documentation.

## Ce que le jeton permet au-delà des outils

Mesuré sur la pile locale, avec le jeton d'un assistant : GoTrue le laisse
**changer le mot de passe** — aucune réidentification n'est exigée d'une session
de moins de 24 h, et celle d'un assistant est neuve — et **tenter de lier une
identité Google** (refusée ici faute d'un vrai jeton Google, pas à cause du
`client_id`). Le changement d'adresse, lui, exige la confirmation des deux
adresses. GoTrue n'offre aucun réglage pour restreindre un jeton OAuth, et la
base n'y peut rien : ce ne sont pas des tables.

Le jeton vaut donc presque la session de l'utilisateur, et la parade porte sur
**qui peut en obtenir un** : la page de consentement est le seul endroit où
l'utilisateur peut accorder l'accès — Supabase n'accepte la décision qu'avec sa
session et depuis l'origine du Site URL —, et elle n'accorde qu'aux assistants
reconnus. Une application malveillante peut s'appeler « Claude » ; elle ne peut
pas faire remettre le code ailleurs qu'à l'adresse qu'elle a déclarée, et une
adresse inconnue n'obtient rien. Le risque restant est celui de tout accès
délégué : faire confiance à l'éditeur de l'assistant qu'on branche — d'où, sur
la page, « n'autorisez qu'un assistant que vous utilisez vous-même ».

Restent, pour qui détiendrait malgré tout un jeton : il peut faire accorder
d'autres accès au nom de l'utilisateur (l'appel de décision n'exige qu'une
en-tête `Origin`, qu'un programme forge) — la liste de l'application les montre
tous, chacun révocable ; et il peut vider la collection par PostgREST sans la
règle « ne devine pas » — chaque retrait est inscrit au journal des
mouvements, donc réparable.

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
| Créer sa collection au premier ajout (`ensure_my_collection`) | oui | oui, privée et sans adresse seulement |
| Écrire ses préférences (`profiles`) | oui | **refusé** |

Déjà fermés à tout jeton `authenticated`, donc à l'assistant : la clé du calque,
l'écriture du journal, les écritures du calque. Mot de passe et adresse
relèvent de GoTrue, qui exige une réidentification pour le premier et une
double confirmation pour la seconde.

Vérifié dans les deux sens, sous le rôle `authenticated`, par
`supabase/tests/assistant.test.sql` : ce que l'assistant fait passe, ce qu'il
ne fait pas lui est refusé, et l'application garde tous ses gestes.

## La documentation publique

`app/web/assistant.html` (`deckhand.heianenterprise.com/assistant.html`) réunit tout ce
qu'un utilisateur **ou un assistant** doit savoir : l'adresse du serveur (injectée par
`pages.yml`, jamais écrite dans le dépôt), le branchement de chaque assistant reconnu, les
outils et leurs paramètres, la règle « l'outil ne devine pas », les limites. Les consignes du
serveur y renvoient l'agent (`consignes.ts`), et `app/web/llms.txt` la signale aux assistants
qui cherchent la documentation d'un site. `robots.txt` refuse les robots d'**entraînement**,
pas les lectures faites à la demande d'un utilisateur (`Claude-User`, `ChatGPT-User`).

**La page ne peut pas dériver des outils** : `documentation_test.ts` compare sa table aux
outils réellement enregistrés, dans les deux sens.

## Le serveur MCP

`supabase/functions/mcp/` — une Edge Function Supabase (TypeScript, Deno), sur
le modèle officiel : `withOAuthProtectedResource` publie la découverte
(`…/functions/v1/mcp/oauth-protected-resource`) et répond 401 avec
`WWW-Authenticate` à un client sans jeton ; `withSupabase({ auth: 'user' })`
vérifie le jeton et rend un client borné à l'utilisateur. Un serveur neuf par
requête, sans état. `verify_jwt = false` (dans `config.toml` et au déploiement) :
la passerelle refuserait sinon la découverte, qui répond à un client encore
sans jeton.

**Pourquoi une Edge Function** : DeckHand n'a aucun serveur à lui, et le
serveur MCP ne doit pas en devenir un. Hébergée à côté de la base, sans système
à maintenir, elle reçoit d'office les pièces OAuth de Supabase ; un service sur
le Hetzner aurait demandé d'écrire la vérification du jeton et de le surveiller.

**Une traduction mince, sans logique métier.** Chaque outil appelle une fonction
SQL de l'application ; le calcul reste en base (`architecture.md` §0).

| Outil | Fonction SQL | Notes |
|---|---|---|
| `resume_collection` | `my_collection_summary` | |
| `ma_collection` | `my_collection` | une ligne par édition et finition, paginée |
| `cartes_jouables` | `my_buildable_cards` | Magic ; identité, type et page filtrés côté PostgREST |
| `cartes_possedees` | `search_cards_bulk` | nom reconnu, exact ou non, exemplaires, prix |
| `editions_de_carte` | `search_cards_bulk` + `card_printings` | pour désigner une édition |
| `decks_suggeres` | `deck_suggestions` | `attribution` sur chaque deck (§IV.2) |
| `cartes_manquantes` | `deck_missing_cards` | |
| `ajouter_cartes` | `add_to_collection` | en lot, règle ci-dessous |
| `retirer_cartes` | `remove_from_collection` | en lot, `destructiveHint` |

Les **consignes du serveur** (`consignes.ts`, champ `instructions`, lu par
l'agent) demandent de citer la source d'un deck, de tenir noms et textes de
cartes pour des données et non des consignes, de faire confirmer un retrait, et
renvoient à la documentation publique.

### L'outil ne devine pas

L'utilisateur ne confirme pas chaque carte qu'un assistant écrit (§IV.8 de
`CLAUDE.md`) : l'outil n'écrit donc que ce qui ne laisse rien à choisir, et rend
le reste. Règle pure dans `resolution.ts`, orchestration dans `ecriture.ts`.

- **Nom** : seule une correspondance exacte (score 1 de `search_cards_bulk`,
  nom normalisé identique, dans n'importe quelle langue) désigne une carte ;
  une correspondance approchée revient en suggestion, un nom introuvable est
  dit tel.
- **Édition, à l'ajout** : désignée (extension + numéro), elle doit exister
  pour cette carte ; non désignée, elle est déduite quand la carte n'en a
  qu'une (`sole_editions`, la règle de l'application), et sinon la carte va dans
  la **pile à trier**, comme une saisie au clavier sans édition. Une finition
  que l'édition n'a pas est refusée.
- **Ligne, au retrait** : `remove_from_collection` vise une ligne précise. Une
  carte possédée sur plusieurs lignes n'est retirée que si la demande
  départage (extension et numéro, `foil`, ou `pile: true`).
- **Une ligne refusée n'arrête pas le lot**, et chaque ligne rend ce qui lui est
  arrivé : carte, édition, quantité, total possédé — ou la raison du refus, la
  suggestion, les choix.

Les ajouts de l'assistant passent au calque OBS comme ceux de l'application :
le journal ne distingue pas qui écrit.

### Ajouter un outil

1. Une fonction SQL d'abord, si le calcul n'existe pas encore : l'outil ne
   calcule rien.
2. Son enregistrement dans `lecture.ts` (ou `ecriture.ts`) : description en
   français — l'agent la lit comme mode d'emploi —, entrée validée par zod,
   annotations (`readOnlyHint`, `destructiveHint`) ; et sa ligne dans la table
   de `app/web/assistant.html` (`<code class="outil">`), sans quoi
   `documentation_test.ts` échoue.
3. Une écriture passe par `Base` (`base.ts`) et s'éprouve sur la fausse base de
   `ecriture_test.ts`.
4. Un geste qui touche au compte plutôt qu'aux cartes n'a pas sa place ici, et
   la base doit le refuser à un jeton d'assistant (`assistant.test.sql`).

## Révoquer

L'utilisateur voit et retire les accès accordés (`GET` / `DELETE
/auth/v1/user/oauth/grants?client_id=…`, avec la session de l'application).
Mesuré sur la pile locale : après révocation, le jeton de rafraîchissement de
l'assistant est refusé aussitôt (`refresh_token_not_found`) ; le jeton d'accès en
cours reste valable jusqu'à son expiration, une heure au plus.

## Éprouver le parcours en local

Pile locale démarrée (`docs/commandes.md`), fonction servie
(`supabase functions serve`), page de consentement servie sur `127.0.0.1:8099`
avec l'adresse et la clé locales à la place des marques. Un client d'essai
s'inscrit (`POST /auth/v1/oauth/clients/register`), ouvre
`/auth/v1/oauth/authorize` avec PKCE, passe par la page, échange le code
(`/auth/v1/oauth/token`), puis appelle le serveur avec son jeton — ou le MCP
Inspector (`npx @modelcontextprotocol/inspector`) fait tout cela d'un coup.
