"""Pousse la configuration d'authentification vers Supabase : SMTP et gabarits.

**Pourquoi un script et non la console.** Trois réglages décident si la route du
mot de passe fonctionne, et aucun ne vit dans la base : le serveur d'envoi,
l'adresse de retour autorisée, et le texte du courriel. Réglés à la main, ils
n'ont ni historique ni revue — et un gabarit qui parle au nom du produit mérite
les deux. Le CLI Supabase ferait le travail mais exige un lien interactif que ce
projet n'utilise pas, pour la même raison que les migrations passent par
`apply_migration.py`.

**Ce que le destinataire voit vient d'ici**, pas du compte Brevo : le nom
d'expéditeur, l'adresse, le sujet et le corps sont des réglages du projet
Supabase. Le compte Brevo n'est qu'un relais, et son identifiant de connexion
n'apparaît jamais dans le message — c'est ce qui permet de partager un compte
entre deux applications sans qu'aucune ne laisse de trace chez l'autre.

Le script est **idempotent** : le rejouer réapplique le même état.

Usage :
    cd api && .venv/Scripts/python push_auth_config.py          # applique
    cd api && .venv/Scripts/python push_auth_config.py --verifier # lecture seule
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import httpx

RACINE = Path(__file__).resolve().parent.parent.parent
COFFRE = RACINE / ".deckhand-secrets"

#: Le relais est une ressource **transverse**, partagée avec DewDrop : sa clé
#: vit à la racine des projets et non dans le coffre de celui-ci, sur le modèle
#: de `.play-secrets/`. La dupliquer par application donnerait deux endroits à
#: mettre à jour lors d'une rotation, donc un des deux oublié — et une
#: application qui cesse d'envoyer sans que rien ne le signale.
#: Voir `../../brevo-email-guide.md`.
COFFRE_BREVO = RACINE / ".brevo-secrets"

GABARITS = Path(__file__).resolve().parent.parent / "supabase" / "templates"

#: Le sujet porte le nom du produit : c'est ce qui rend les courriels de
#: l'application filtrables dans une boîte de réception.
SUJET_RECOVERY = "DeckHand — nouveau mot de passe"


def lire_env(nom: str, coffre: Path = COFFRE) -> dict[str, str]:
    valeurs: dict[str, str] = {}
    chemin = coffre / nom
    if not chemin.exists():
        raise SystemExit(f"coffre introuvable : {chemin}")
    for ligne in chemin.read_text(encoding="utf-8").splitlines():
        ligne = ligne.strip()
        if ligne and not ligne.startswith("#") and "=" in ligne:
            cle, _, valeur = ligne.partition("=")
            valeurs[cle.strip()] = valeur.strip().strip("\"'")
    return valeurs


def main() -> int:
    supabase = lire_env("supabase.env")
    brevo = lire_env("brevo-smtp.env", COFFRE_BREVO)

    ref = re.sub(r"https?://([^.]+)\..*", r"\1", supabase["SUPABASE_URL"])
    entetes = {"Authorization": f"Bearer {supabase['SUPABASE_ACCESS_TOKEN']}"}
    url = f"https://api.supabase.com/v1/projects/{ref}/config/auth"

    if "--verifier" in sys.argv:
        return rapporter(httpx.get(url, headers=entetes, timeout=30).json())

    recovery = (GABARITS / "recovery.html").read_text(encoding="utf-8")
    # Le lien substitué par Supabase est ce qui fait le courriel : sans lui, le
    # message part et ne mène nulle part, ce qu'aucune erreur ne signalerait.
    if "{{ .ConfirmationURL }}" not in recovery:
        raise SystemExit("recovery.html ne contient pas {{ .ConfirmationURL }}")

    reponse = httpx.patch(
        url,
        headers=entetes,
        json={
            "smtp_host": brevo["BREVO_SMTP_HOST"],
            "smtp_port": brevo["BREVO_SMTP_PORT"],
            "smtp_user": brevo["BREVO_SMTP_USER"],
            "smtp_pass": brevo["BREVO_SMTP_KEY"],
            "smtp_admin_email": brevo["BREVO_SENDER_EMAIL"],
            "smtp_sender_name": brevo["BREVO_SENDER_NAME"],
            # Le relais de démonstration plafonnait à deux courriels par heure,
            # ce qui suffisait à faire échouer une seconde tentative.
            "rate_limit_email_sent": 30,
            "mailer_subjects_recovery": SUJET_RECOVERY,
            "mailer_templates_recovery_content": recovery,
        },
        timeout=60,
    )
    if reponse.status_code != 200:
        print(f"échec ({reponse.status_code}) : {reponse.text[:400]}")
        return 1

    return rapporter(reponse.json())


def rapporter(cfg: dict) -> int:
    gabarit = cfg.get("mailer_templates_recovery_content") or ""
    print(f"expéditeur        : {cfg.get('smtp_sender_name')} "
          f"<{cfg.get('smtp_admin_email')}>")
    print(f"relais            : {cfg.get('smtp_host') or '(démo Supabase)'}")
    print(f"sujet             : {cfg.get('mailer_subjects_recovery')}")
    print(f"gabarit recovery  : {len(gabarit)} caractères"
          f"{' — sur mesure' if 'DeckHand' in gabarit else ' — PAR DÉFAUT'}")
    print(f"retours autorisés : {cfg.get('uri_allow_list')}")
    print(f"courriels par heure : {cfg.get('rate_limit_email_sent')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
