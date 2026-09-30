/**
 * suppression-compte.js — Supprime un compte DeckHand depuis le web, sans
 * l'application (Google Play exige une adresse de suppression pour toute
 * application à comptes).
 *
 * Deux appels REST, sans bibliothèque : une connexion (mot de passe, ou jeton
 * d'identité Google), puis `delete_my_account`, la même fonction que
 * l'application appelle. Elle ne supprime que le titulaire du jeton ; la base
 * efface le reste en cascade.
 *
 * Choix non évidents :
 * - L'adresse du serveur et la clé publiable sont injectées à la compilation
 *   par `.github/workflows/pages.yml` (secrets d'actions), jamais écrites dans
 *   le dépôt ni lues depuis l'adresse de la page : un lien piégé enverrait
 *   sinon le mot de passe à un autre serveur. La compilation échoue si l'une
 *   des deux marques ci-dessous reste en place.
 * - Jetons en mémoire seulement (ni localStorage ni cookie) ; « Annuler » et la
 *   fermeture de la page révoquent la session côté serveur.
 * - Google : le script officiel (Google Identity Services) n'est chargé qu'au
 *   clic sur « Continuer avec Google », jamais pour un simple visiteur. Son
 *   bouton rend un jeton d'identité, échangé auprès de Supabase (grant
 *   `id_token`) : ni redirection ni secret Google.
 * - Un compte Google sans compte DeckHand en crée un à la connexion (Supabase
 *   n'a pas d'interrupteur d'inscription par fournisseur) : la page le détecte
 *   (créé par cette connexion même) et le supprime aussitôt, sans rien garder.
 * - GitHub Pages ne permet pas l'en-tête `frame-ancestors` : le script refuse
 *   de tourner dans un cadre (anti-clickjacking).
 * - Messages neutres (guide de conformité, C2) : mauvais identifiants et
 *   adresse non confirmée donnent le même message.
 *
 * Invariants :
 * - GOOGLE_CLIENT_ID = `kGoogleWebClientId` de l'application = client du
 *   fournisseur Google du projet Supabase (`api/push_auth_config.py`) ; son
 *   « origine JavaScript autorisée » est https://deckhand.heianenterprise.com.
 */
(function () {
  'use strict';

  const SUPABASE_URL = '__SUPABASE_URL__';
  const SUPABASE_KEY = '__SUPABASE_PUBLISHABLE_KEY__';
  const GOOGLE_CLIENT_ID = '606067636388-an9rtthrnsd18te5v78uesqd4cvepn3p.apps.googleusercontent.com';
  const SCRIPT_GOOGLE = 'https://accounts.google.com/gsi/client';
  const MOT_DE_CONFIRMATION = 'SUPPRIMER';
  // Écart maximal entre création et connexion pour un compte que la connexion
  // Google vient elle-même de créer.
  const COMPTE_NEUF_MS = 10 * 1000;

  const MESSAGES = {
    identifiants: 'Connexion impossible : vérifiez votre adresse et votre mot de passe. ' +
      'Un compte jamais confirmé ne peut pas se connecter ; il est effacé de lui-même au bout de 7 jours.',
    tropDEssais: 'Trop de tentatives. Réessayez dans quelques minutes.',
    reseau: 'Le serveur ne répond pas. Vérifiez votre connexion, puis réessayez.',
    echec: "La suppression n'a pas abouti. Réessayez, ou écrivez-nous : elle sera faite à la main.",
    mot: 'Écrivez SUPPRIMER (en majuscules) pour confirmer.',
    vide: 'Renseignez votre adresse et votre mot de passe.',
    google: "La connexion avec Google n'a pas abouti. Réessayez.",
  };

  let session = null; // { accessToken, email, neuf } — en mémoire, jamais stockée

  const $ = (id) => document.getElementById(id);

  function statut(texte, erreur) {
    const el = $('statut');
    el.textContent = texte || '';
    el.classList.toggle('error', Boolean(erreur));
  }

  function afficher(etape) {
    for (const id of ['connexion', 'confirmation', 'termine', 'rien']) {
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

  function seConnecter(email, motDePasse) {
    return ouvrirSession('/auth/v1/token?grant_type=password',
      { email: email, password: motDePasse }, 'identifiants');
  }

  async function seDeconnecter() {
    if (!session) return;
    const jeton = session.accessToken;
    session = null;
    try {
      await appeler('/auth/v1/logout', { headers: { Authorization: 'Bearer ' + jeton }, keepalive: true });
    } catch (_) {
      // Le jeton d'accès expire seul au bout d'une heure ; rien d'autre à faire.
    }
  }

  async function supprimer() {
    const reponse = await appeler('/rest/v1/rpc/delete_my_account', {
      headers: { Authorization: 'Bearer ' + session.accessToken },
      body: '{}',
    });
    if (!reponse.ok) throw new Error('echec');
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
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
      return;
    }
    if (session.neuf) {
      // Aucun compte DeckHand derrière ce compte Google : la connexion vient
      // d'en créer un, qu'on efface aussitôt pour ne rien garder.
      try {
        await supprimer();
        session = null;
        afficher('rien');
        statut('');
      } catch (_) {
        statut(MESSAGES.echec, true);
      }
      return;
    }
    montrerConfirmation();
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
      session = await seConnecter(email, motDePasse);
      $('password').value = '';
      montrerConfirmation();
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
    } finally {
      occupe(form, false);
    }
  }

  function montrerConfirmation() {
    $('compte').textContent = session.email;
    afficher('confirmation');
    statut('');
    $('mot').focus();
  }

  async function surConfirmation(evenement) {
    evenement.preventDefault();
    const form = evenement.currentTarget;
    if ($('mot').value.trim() !== MOT_DE_CONFIRMATION) {
      statut(MESSAGES.mot, true);
      return;
    }
    occupe(form, true);
    statut('Suppression…');
    try {
      await supprimer();
      session = null; // le compte n'existe plus : sa session non plus
      afficher('termine');
      statut('');
    } catch (erreur) {
      statut(MESSAGES[erreur.message] || MESSAGES.reseau, true);
    } finally {
      occupe(form, false);
    }
  }

  async function surAnnulation() {
    await seDeconnecter();
    $('mot').value = '';
    afficher('connexion');
    statut("Vous êtes déconnecté. Votre compte n'a pas été supprimé.");
  }

  function demarrer() {
    if (window.top !== window.self) {
      statut("Cette page ne peut pas s'ouvrir dans un cadre. Ouvrez-la directement.", true);
      return;
    }
    $('connexion').addEventListener('submit', surConnexion);
    $('confirmation').addEventListener('submit', surConfirmation);
    $('annuler').addEventListener('click', surAnnulation);
    $('google').addEventListener('click', versGoogle);
    window.addEventListener('pagehide', seDeconnecter);
    afficher('connexion');
  }

  demarrer();
})();
