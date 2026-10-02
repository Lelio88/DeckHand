/**
 * oauth-consent.js — La page où l'on autorise (ou refuse) un assistant IA à
 * agir sur sa collection DeckHand, au milieu du parcours OAuth 2.1 que mène
 * Supabase Auth pour le serveur MCP (`supabase/functions/mcp/`).
 *
 * Supabase Auth envoie l'utilisateur ici avec `?authorization_id=…`. La page
 * le connecte, montre qui demande et où l'autorisation sera remise, puis
 * transmet la décision ; Supabase rend alors l'adresse de retour de
 * l'assistant, munie du code (accord) ou d'une erreur (refus).
 *
 * Trois appels REST, sans bibliothèque :
 *   1. connexion — mot de passe, ou jeton d'identité Google (`grant_type=id_token`) ;
 *   2. `GET  /auth/v1/oauth/authorizations/{id}` — qui demande, et pour où ;
 *   3. `POST /auth/v1/oauth/authorizations/{id}/consent` — `approve` ou `deny`.
 *
 * Choix non évidents :
 * - **Jumelle de `suppression-compte.js`** pour la connexion : adresse et clé
 *   injectées à la compilation par `pages.yml` (jamais lues depuis l'URL, qui
 *   enverrait sinon le mot de passe ailleurs), jetons en mémoire seulement,
 *   bouton Google chargé au clic, refus de tourner dans un cadre, messages
 *   neutres. Une correction de l'une vaut probablement pour l'autre.
 * - **Déconnexion locale** (`/logout?scope=local`) : seule la session ouverte
 *   par cette page est fermée. Sans paramètre, GoTrue ferme toutes les
 *   sessions du compte, téléphone compris. L'autorisation accordée n'en
 *   dépend pas : l'assistant reçoit la sienne en échangeant le code.
 * - **Un consentement déjà donné** au même assistant fait répondre l'étape 2
 *   directement par une adresse de retour : on y va sans redemander.
 * - **L'adresse de retour est montrée** avant l'accord : c'est le seul moyen
 *   de reconnaître une application qui se ferait passer pour un assistant
 *   connu, l'inscription des clients étant ouverte. Une adresse en
 *   `javascript:`, `data:` ou `vbscript:` n'est jamais suivie.
 * - **Un compte Google sans compte DeckHand** en crée un à la connexion ; il
 *   est supprimé aussitôt, comme sur la page de suppression. Sa session est
 *   celle de cette page, sans `client_id` : la garde de l'assistant
 *   (`20261002100000_garde_assistant.sql`) ne la concerne pas.
 *
 * Invariants :
 * - Supabase vérifie que les appels 2 et 3 viennent de l'origine du Site URL
 *   (`api/push_auth_config.py`, `SITE`) : la page n'est servie que là.
 * - Tout texte venu du serveur passe par `textContent`, jamais par du HTML :
 *   le nom d'un client est choisi par qui l'inscrit.
 */
(function () {
  'use strict';

  const SUPABASE_URL = '__SUPABASE_URL__';
  const SUPABASE_KEY = '__SUPABASE_PUBLISHABLE_KEY__';
  const GOOGLE_CLIENT_ID = '606067636388-an9rtthrnsd18te5v78uesqd4cvepn3p.apps.googleusercontent.com';
  const SCRIPT_GOOGLE = 'https://accounts.google.com/gsi/client';
  // Écart maximal entre création et connexion pour un compte que la connexion
  // Google vient elle-même de créer.
  const COMPTE_NEUF_MS = 10 * 1000;
  const SCHEMAS_INTERDITS = ['javascript:', 'data:', 'vbscript:'];

  const MESSAGES = {
    identifiants: 'Connexion impossible : vérifiez votre adresse et votre mot de passe. ' +
      'Un compte jamais confirmé ne peut pas se connecter.',
    tropDEssais: 'Trop de tentatives. Réessayez dans quelques minutes.',
    reseau: 'Le serveur ne répond pas. Vérifiez votre connexion, puis réessayez.',
    echec: "L'opération n'a pas abouti. Relancez la connexion depuis votre assistant.",
    vide: 'Renseignez votre adresse et votre mot de passe.',
    google: "La connexion avec Google n'a pas abouti. Réessayez.",
    retour: "L'adresse de retour de cet assistant n'est pas sûre : rien n'a été suivi.",
  };

  const autorisation = new URLSearchParams(window.location.search).get('authorization_id');
  let session = null; // { accessToken, email, neuf } — en mémoire, jamais stockée

  const $ = (id) => document.getElementById(id);

  function statut(texte, erreur) {
    const el = $('statut');
    el.textContent = texte || '';
    el.classList.toggle('error', Boolean(erreur));
  }

  function afficher(etape) {
    for (const id of ['connexion', 'demande', 'envoye', 'invalide', 'rien']) {
      $(id).hidden = id !== etape;
    }
  }

  function occupe(form, oui) {
    for (const bouton of form.querySelectorAll('button')) bouton.disabled = oui;
  }

  function appeler(chemin, options) {
    return fetch(SUPABASE_URL + chemin, {
      method: 'POST',
      credentials: 'omit',
      cache: 'no-store',
      ...options,
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json', ...options.headers },
    });
  }

  function avecJeton() {
    return { Authorization: 'Bearer ' + session.accessToken };
  }

  async function ouvrirSession(chemin, corpsRequete, erreur) {
    const reponse = await appeler(chemin, { body: JSON.stringify(corpsRequete), headers: {} });
    if (reponse.status === 429) throw new Error('tropDEssais');
    if (!reponse.ok) throw new Error(erreur);
    const corps = await reponse.json();
    if (!corps.access_token) throw new Error(erreur);
    const user = corps.user || {};
    return {
      accessToken: corps.access_token,
      email: user.email || corpsRequete.email || '',
      neuf: Date.parse(user.last_sign_in_at) - Date.parse(user.created_at) < COMPTE_NEUF_MS,
    };
  }

  async function seDeconnecter() {
    if (!session) return;
    const jeton = session.accessToken;
    session = null;
    try {
      await appeler('/auth/v1/logout?scope=local', {
        headers: { Authorization: 'Bearer ' + jeton },
        keepalive: true,
      });
    } catch (_) {
      // Le jeton d'accès expire seul au bout d'une heure ; rien d'autre à faire.
    }
  }

  /** Suit l'adresse de retour rendue par Supabase, sauf schéma exécutable. */
  async function retournerVers(adresse) {
    let cible;
    try {
      cible = new URL(adresse);
    } catch (_) {
      throw new Error('retour');
    }
    if (SCHEMAS_INTERDITS.includes(cible.protocol)) throw new Error('retour');
    await seDeconnecter();
    afficher('envoye');
    statut('');
    window.location.assign(cible.href);
  }

  function chemin() {
    return '/auth/v1/oauth/authorizations/' + encodeURIComponent(autorisation);
  }

  /** Étape 2 : qui demande, et pour où — ou retour direct si déjà consenti. */
  async function chargerDemande() {
    const reponse = await appeler(chemin(), { method: 'GET', headers: avecJeton() });
    if (reponse.status === 404 || reponse.status === 400) {
      await seDeconnecter();
      afficher('invalide');
      statut('');
      return;
    }
    if (!reponse.ok) throw new Error('echec');
    const details = await reponse.json();
    if (details.redirect_url) {
      await retournerVers(details.redirect_url);
      return;
    }
    montrerDemande(details);
  }

  function hoteDe(adresse) {
    try {
      const url = new URL(adresse);
      return url.host ? url.protocol + '//' + url.host : url.protocol;
    } catch (_) {
      return adresse || '(inconnue)';
    }
  }

  function montrerDemande(details) {
    const client = details.client || {};
    $('client').textContent = client.name || 'Un assistant sans nom';
    $('compte').textContent = (details.user && details.user.email) || session.email;
    $('retour').textContent = hoteDe(details.redirect_uri);
    afficher('demande');
    statut('');
  }

  async function decider(action) {
    const reponse = await appeler(chemin() + '/consent', {
      headers: avecJeton(),
      body: JSON.stringify({ action: action }),
    });
    if (!reponse.ok) throw new Error('echec');
    const corps = await reponse.json();
    if (!corps.redirect_url) throw new Error('echec');
    await retournerVers(corps.redirect_url);
  }

  async function apresConnexion() {
    if (session.neuf) {
      // Aucun compte DeckHand derrière ce compte Google : la connexion vient
      // d'en créer un, qu'on efface aussitôt pour ne rien garder.
      const reponse = await appeler('/rest/v1/rpc/delete_my_account', {
        headers: avecJeton(),
        body: '{}',
      });
      if (!reponse.ok) throw new Error('echec');
      session = null;
      afficher('rien');
      statut('');
      return;
    }
    await chargerDemande();
  }

  function chargerGoogle() {
    return new Promise((resoudre, rejeter) => {
      if (window.google && window.google.accounts) {
        resoudre();
        return;
      }
      const script = document.createElement('script');
      script.src = SCRIPT_GOOGLE;
      script.async = true;
      script.onload = () => resoudre();
      script.onerror = () => rejeter(new Error('google'));
      document.head.appendChild(script);
    });
  }

  /** Au clic : charge le bouton officiel de Google à la place du nôtre. */
  async function versGoogle() {
    const bouton = $('google');
    bouton.disabled = true;
    statut('Chargement du bouton Google…');
    try {
      await chargerGoogle();
    } catch (_) {
      bouton.disabled = false;
      statut(MESSAGES.google, true);
      return;
    }
    window.google.accounts.id.initialize({
      client_id: GOOGLE_CLIENT_ID,
      callback: surJetonGoogle,
      ux_mode: 'popup',
      auto_select: false,
    });
    bouton.hidden = true;
    window.google.accounts.id.renderButton($('google-officiel'), {
      type: 'standard',
      theme: 'outline',
      size: 'large',
      text: 'continue_with',
      shape: 'rectangular',
      locale: 'fr',
    });
    statut('Choisissez votre compte Google avec le bouton ci-dessus.');
  }

  /** Jeton d'identité rendu par Google : l'échanger contre une session. */
  async function surJetonGoogle(reponse) {
    if (!reponse || !reponse.credential) {
      statut(MESSAGES.google, true);
      return;
    }
    statut('Connexion…');
    try {
      session = await ouvrirSession('/auth/v1/token?grant_type=id_token',
        { provider: 'google', id_token: reponse.credential }, 'google');
      await apresConnexion();
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
    }
  }

  async function surConnexion(evenement) {
    evenement.preventDefault();
    const form = evenement.currentTarget;
    const email = $('email').value.trim();
    const motDePasse = $('password').value;
    if (!email || !motDePasse) {
      statut(MESSAGES.vide, true);
      return;
    }
    occupe(form, true);
    statut('Connexion…');
    try {
      session = await ouvrirSession('/auth/v1/token?grant_type=password',
        { email: email, password: motDePasse }, 'identifiants');
      $('password').value = '';
      await apresConnexion();
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
    } finally {
      occupe(form, false);
    }
  }

  async function surDecision(evenement, action) {
    if (evenement) evenement.preventDefault();
    const form = $('demande');
    occupe(form, true);
    statut(action === 'approve' ? 'Autorisation…' : 'Refus…');
    try {
      await decider(action);
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
      occupe(form, false);
    }
  }

  async function surChangement() {
    await seDeconnecter();
    afficher('connexion');
    statut('Vous êtes déconnecté. Connectez-vous avec le bon compte.');
  }

  function demarrer() {
    if (window.top !== window.self) {
      statut("Cette page ne peut pas s'ouvrir dans un cadre. Ouvrez-la directement.", true);
      return;
    }
    if (!autorisation) {
      afficher('invalide');
      return;
    }
    $('connexion').addEventListener('submit', surConnexion);
    $('demande').addEventListener('submit', (e) => surDecision(e, 'approve'));
    $('refuser').addEventListener('click', () => surDecision(null, 'deny'));
    $('changer').addEventListener('click', surChangement);
    $('google').addEventListener('click', versGoogle);
    window.addEventListener('pagehide', seDeconnecter);
    afficher('connexion');
  }

  demarrer();
})();
