"""Upload a signed AAB to Google Play through the Android Publisher API v3.

Does exactly what the Play Console upload flow does: open an *edit*, upload the
bundle, point a track's release at the returned version code, attach release
notes, validate, commit. Nothing reaches testers until the commit — a run that
dies halfway leaves the live track untouched.

Project-agnostic on purpose: the same file is dropped into every app repo
(dewdrop, LLMarmite, GTG, CulturiaQuests) and works out of the box for both
Flutter and Capacitor/Gradle projects. It figures out on its own:
  - the repo root (nearest ancestor holding .git),
  - the app module (the directory holding android/app/build.gradle[.kts]),
  - the applicationId, versionCode and versionName,
  - where the built AAB lands,
  - where the service-account JSON lives.
Run with --show-config to print all of it without touching the network.

Non-obvious choices:
- The service-account JSON lives OUTSIDE the repo (these repos are public).
  Looked up in ../.<repo>-secrets/play-sa.json, then ../.play-secrets/play-sa.json
  (one Play developer account can serve every app), then $PLAY_SERVICE_ACCOUNT_JSON.
- Building is deliberately NOT part of this script. A bundle built without its
  --dart-define / `npm run sync` step compiles fine and fails at runtime, so the
  build stays an explicit, reviewable step documented in each repo's CLAUDE.md.
- The version code inside the uploaded bundle is checked against the project
  manifest and mismatches abort: shipping a stale AAB to testers is the
  expensive mistake this guards against (--allow-version-mismatch to override).
- `production` requires --yes-production. Grant the service account
  test-track-only rights in Play Console and even that flag cannot reach prod.
- --dry-run really does upload the bundle (only the commit is skipped), but the
  version code is NOT burned: the abandoned edit takes the upload with it.
  Verified on dewdrop 0.9.10+24 — dry-run then real publish, same code 24, no
  "already been used". So a dry-run is always safe to run first.

Requires: google-auth, requests.

Run:
  python <path>/publish_play.py --show-config
  python <path>/publish_play.py --list-tracks
  python <path>/publish_play.py --track alpha --dry-run
  python <path>/publish_play.py --track alpha --notes-file notes.txt
"""

import argparse
import os
import re
import sys

# Windows consoles default to cp1252, which cannot encode the arrows/ellipses
# below (nor the emojis a CHANGELOG carries) — printing would raise
# UnicodeEncodeError mid-publish. Force UTF-8 with a lenient fallback.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # non-reconfigurable stream
        pass

try:
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account
except ImportError:  # pragma: no cover - dependency guidance
    sys.exit("Manque google-auth : pip install google-auth requests")

SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = ("https://androidpublisher.googleapis.com/upload/androidpublisher/v3"
          "/applications")
# Play truncates anything longer, per language.
MAX_NOTES = 500
# Directories that never hold the app module and cost seconds to walk.
SKIP_DIRS = {".git", "node_modules", "build", ".gradle", ".dart_tool", "dist",
             "www", "vendor", ".venv", "venv", "__pycache__", "ios"}


def fail(msg):
    sys.exit(f"\n[X] {msg}")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


# ── Project discovery ────────────────────────────────────────────────────────

def find_repo_root(start):
    """Nearest ancestor holding .git — so the script works from any subfolder."""
    path = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            # No .git (fresh export): fall back to the script's grandparent.
            return os.path.abspath(os.path.join(os.path.dirname(start), ".."))
        path = parent


def gradle_path(app_dir):
    for name in ("build.gradle", "build.gradle.kts"):
        candidate = os.path.join(app_dir, "android", "app", name)
        if os.path.isfile(candidate):
            return candidate
    return None


def find_app_dirs(repo):
    """Directories holding android/app/build.gradle[.kts], repo root included."""
    found = []
    for current, dirs, _ in os.walk(repo):
        rel = os.path.relpath(current, repo)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > 2:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        if gradle_path(current):
            found.append(current)
    return found


def detect_version(app_dir, gradle_text):
    """(versionName, versionCode, source). Flutter's pubspec wins when present:
    its `version: x.y.z+N` is what the Gradle file interpolates."""
    pubspec = os.path.join(app_dir, "pubspec.yaml")
    if os.path.isfile(pubspec):
        match = re.search(r"^version:\s*([0-9.]+)\+(\d+)", read(pubspec), re.M)
        if match:
            return match.group(1), int(match.group(2)), "pubspec.yaml"
    # Capacitor / plain Android: literals in the Gradle file. `versionCode =
    # flutter.versionCode` deliberately does not match the digit pattern.
    code = re.search(r"versionCode\s*=?\s*(\d+)", gradle_text)
    name = re.search(r'versionName\s*=?\s*"([^"]+)"', gradle_text)
    if not code:
        return (name.group(1) if name else "?"), None, "build.gradle"
    return (name.group(1) if name else "?"), int(code.group(1)), "build.gradle"


def detect_package(gradle_text):
    match = re.search(r'applicationId\s*=?\s*"([^"]+)"', gradle_text)
    if not match:  # some templates only set the namespace
        match = re.search(r'namespace\s*=?\s*"([^"]+)"', gradle_text)
    return match.group(1) if match else None


def default_aab(app_dir, is_flutter):
    if is_flutter:
        return os.path.join(app_dir, "build", "app", "outputs", "bundle",
                            "release", "app-release.aab")
    return os.path.join(app_dir, "android", "app", "build", "outputs", "bundle",
                        "release", "app-release.aab")


def credential_candidates(repo):
    """Vault of the project first, then a shared one — a single Play developer
    account can publish every app, so one JSON may serve them all."""
    parent = os.path.dirname(repo)
    slug = os.path.basename(repo).lower()
    return [
        os.path.join(parent, f".{slug}-secrets", "play-sa.json"),
        os.path.join(parent, ".play-secrets", "play-sa.json"),
    ]


class Project:
    """Everything the publisher needs, resolved once."""

    def __init__(self, args):
        self.repo = find_repo_root(os.path.dirname(os.path.abspath(__file__)))
        if args.app_dir:
            self.app_dir = os.path.abspath(args.app_dir)
            if not gradle_path(self.app_dir):
                fail(f"Pas de android/app/build.gradle sous {self.app_dir}")
        else:
            found = find_app_dirs(self.repo)
            if not found:
                fail(f"Aucun module Android trouvé sous {self.repo}\n"
                     "    (cherché : */android/app/build.gradle[.kts]) — "
                     "précise --app-dir.")
            if len(found) > 1:
                names = ", ".join(os.path.relpath(f, self.repo) for f in found)
                fail(f"Plusieurs modules Android trouvés ({names}).\n"
                     "    Précise lequel avec --app-dir.")
            self.app_dir = found[0]

        self.gradle = gradle_path(self.app_dir)
        gradle_text = read(self.gradle)
        self.is_flutter = os.path.isfile(os.path.join(self.app_dir,
                                                      "pubspec.yaml"))
        self.package = args.package or detect_package(gradle_text)
        if not self.package:
            fail(f"applicationId introuvable dans {self.gradle} — passe "
                 "--package <com.exemple.app>.")
        self.name, self.code, self.version_source = detect_version(self.app_dir,
                                                                   gradle_text)
        self.aab = os.path.abspath(args.aab) if args.aab else default_aab(
            self.app_dir, self.is_flutter)
        self.credentials = self._resolve_credentials(args.credentials)

    def _resolve_credentials(self, explicit):
        if explicit:
            return os.path.abspath(explicit)
        for candidate in credential_candidates(self.repo):
            if os.path.isfile(candidate):
                return candidate
        return credential_candidates(self.repo)[0]  # for the error message

    def describe(self):
        kind = "Flutter" if self.is_flutter else "Capacitor / Gradle"
        rel = os.path.relpath(self.app_dir, self.repo)
        creds_state = "OK" if os.path.isfile(self.credentials) else "ABSENT"
        aab_state = (f"{os.path.getsize(self.aab) / 1_048_576:.1f} Mo"
                     if os.path.isfile(self.aab) else "pas encore buildé")
        return "\n".join([
            f"  dépôt      {self.repo}",
            f"  module     {rel}  ({kind})",
            f"  paquet     {self.package}",
            f"  version    {self.name}+{self.code}   (via {self.version_source})",
            f"  AAB        {self.aab}  [{aab_state}]",
            f"  compte     {self.credentials}  [{creds_state}]",
        ])


# ── API plumbing ─────────────────────────────────────────────────────────────

def check(resp, what):
    """Surface the API's own error text — it is specific ("Version code 2 has
    already been used", "Package not found") and guessing from a bare 400
    wastes far more time."""
    if resp.status_code >= 400:
        try:
            detail = resp.json()["error"]["message"]
        except (ValueError, KeyError):
            detail = resp.text[:500]
        hint = ""
        low = detail.lower()
        if "already been used" in low:
            # Play reuses 403 for "version code taken", which has nothing to do
            # with permissions — pointing at the invitation would misdirect.
            hint = ("\n    → Ce versionCode est déjà consommé sur Play. Soit il "
                    "est déjà en ligne\n      (utilise --promote <code> pour le "
                    "rattacher à une track), soit il faut\n      incrémenter la "
                    "version du projet et rebuilder.")
        elif resp.status_code in (401, 403) and "permission" in low:
            hint = ("\n    → Le compte de service est-il bien invité sur CETTE "
                    "app dans Play Console ?\n      (la propagation prend "
                    "quelques minutes après l'invitation)")
        elif resp.status_code == 404:
            hint = ("\n    → Paquet inconnu de Play : l'app existe-t-elle dans "
                    "la console,\n      avec une première version envoyée à la "
                    "main ? (prérequis Google)")
        fail(f"{what} → HTTP {resp.status_code}\n    {detail}{hint}")
    return resp.json() if resp.content else {}


def session(creds_path):
    if not os.path.isfile(creds_path):
        fail(f"Service account introuvable : {creds_path}\n"
             "    Crée-le (voir play-store-publication-guide.md § 13) et pose "
             "le JSON à ce chemin,\n    ou passe --credentials <chemin>.")
    creds = service_account.Credentials.from_service_account_file(
        creds_path, scopes=[SCOPE])
    return AuthorizedSession(creds)


def notes_from_changelog(repo):
    """First section of CHANGELOG.md, flattened to the plain text Play wants."""
    path = os.path.join(repo, "CHANGELOG.md")
    if not os.path.isfile(path):
        return ""
    sections = re.split(r"^## ", read(path), flags=re.M)
    if len(sections) < 2:
        return ""
    text = sections[1].split("\n", 1)[1] if "\n" in sections[1] else ""
    text = re.sub(r"^### .*$", "", text, flags=re.M)      # sub-headings
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)          # bold
    text = re.sub(r"\[(.+?)\]\(.+?\)", r"\1", text)       # links
    text = re.sub(r"[ \t]*\n[ \t]+", " ", text)           # unwrap list items
    text = re.sub(r"\n{2,}", "\n", text)
    return text.strip()


def resolve_notes(args, repo):
    if args.notes:
        notes = args.notes
    elif args.notes_file:
        notes = read(args.notes_file).strip()
    else:
        notes = notes_from_changelog(repo)
        if not notes:
            fail("Pas de notes de version : ce dépôt n'a pas de CHANGELOG.md "
                 "exploitable.\n    Utilise --notes-file <fichier> ou "
                 '--notes "texte".')
    if len(notes) > MAX_NOTES:
        fail(f"Notes de version : {len(notes)} caractères, Play en accepte "
             f"{MAX_NOTES}.\n    Raccourcis, ou passe --notes-file avec une "
             "version courte pour les testeurs.")
    return notes


# ── Commands ─────────────────────────────────────────────────────────────────

def list_tracks(sess, project):
    edit = check(sess.post(f"{API}/{project.package}/edits"),
                 "création de l'edit")
    edit_id = edit["id"]
    try:
        data = check(sess.get(f"{API}/{project.package}/edits/{edit_id}/tracks"),
                     "lecture des tracks")
        print(f"\nTracks de {project.package} :\n")
        for track in data.get("tracks", []):
            releases = track.get("releases", [])
            codes = [c for r in releases for c in r.get("versionCodes", [])]
            status = releases[0].get("status", "—") if releases else "—"
            print(f"  {track['track']:<16} versionCodes={codes or '—'}  "
                  f"statut={status}")
        print()
    finally:
        sess.delete(f"{API}/{project.package}/edits/{edit_id}")


def publish(sess, project, args):
    """Uploads the AAB then points the track at it — unless --promote is given,
    in which case an already-uploaded version code is (re)assigned instead. That
    covers the "release stuck in draft" case: the bundle is already on Play, only
    its status has to change, and re-uploading would be rejected as a duplicate
    version code."""
    promoting = args.promote is not None
    if not promoting and not os.path.isfile(project.aab):
        fail(f"AAB introuvable : {project.aab}\n    Build-le d'abord "
             "(commandes dans le CLAUDE.md du projet).")
    notes = resolve_notes(args, project.repo)

    print(f"\n{project.describe()}")
    if promoting:
        print(f"  action     promotion du versionCode {args.promote} "
              "(aucun upload)")
    print(f"  track      {args.track}  (statut « {args.status} »)")
    print(f"  notes      {len(notes)} caractères / {MAX_NOTES}\n")

    pkg = project.package
    edit_id = check(sess.post(f"{API}/{pkg}/edits"), "création de l'edit")["id"]
    committed = False
    try:
        if promoting:
            code = args.promote
        else:
            print("  → upload du bundle…")
            with open(project.aab, "rb") as f:
                uploaded = check(
                    sess.post(
                        f"{UPLOAD}/{pkg}/edits/{edit_id}/bundles?uploadType=media",
                        data=f,
                        headers={"Content-Type": "application/octet-stream"},
                    ),
                    "upload du bundle",
                )
            code = int(uploaded["versionCode"])
            print(f"    versionCode {code}")

        if (not promoting and project.code is not None
                and code != project.code and not args.allow_version_mismatch):
            fail(f"Le bundle porte le versionCode {code}, "
                 f"{project.version_source} annonce {project.code}.\n"
                 "    C'est presque toujours un AAB périmé : rebuild, ou "
                 "--allow-version-mismatch\n    si l'écart est voulu. (Rien "
                 "n'a été publié : l'edit est abandonné.)")

        release = {
            "versionCodes": [str(code)],
            "status": args.status,
            "releaseNotes": [{"language": args.language, "text": notes}],
        }
        check(
            sess.put(f"{API}/{pkg}/edits/{edit_id}/tracks/{args.track}",
                     json={"track": args.track, "releases": [release]}),
            f"assignation à la track {args.track}",
        )
        print(f"  → track « {args.track} » pointée sur {code}")

        check(sess.post(f"{API}/{pkg}/edits/{edit_id}:validate"), "validation")
        print("  → validation OK")

        if args.dry_run:
            print("\n[i] --dry-run : edit abandonné, rien n'est publié.\n")
            return

        check(sess.post(f"{API}/{pkg}/edits/{edit_id}:commit"), "commit")
        committed = True
        print(f"\n[OK] {project.name}+{code} publié sur « {args.track} ».")
        print("     Play met quelques minutes à le proposer aux testeurs.\n")
    finally:
        # An uncommitted edit is inert, but leaving it open helps nobody.
        if not committed:
            sess.delete(f"{API}/{pkg}/edits/{edit_id}")


def main():
    p = argparse.ArgumentParser(
        description="Publie un AAB signé sur Google Play (API officielle).")
    p.add_argument("--track", default="alpha",
                   help="alpha (test fermé), beta (test ouvert), internal, "
                        "production, ou une track personnalisée (défaut: alpha)")
    p.add_argument("--aab", help="chemin de l'AAB (défaut: détecté)")
    p.add_argument("--app-dir", help="module Android (défaut: détecté)")
    p.add_argument("--package", help="applicationId (défaut: lu dans Gradle)")
    p.add_argument("--credentials",
                   default=os.environ.get("PLAY_SERVICE_ACCOUNT_JSON"),
                   help="JSON du service account (défaut: coffre du projet)")
    p.add_argument("--notes", help="notes de version en clair")
    p.add_argument("--notes-file", help="fichier de notes de version")
    p.add_argument("--language", default="fr-FR")
    p.add_argument("--status", default="completed",
                   choices=["completed", "draft", "inProgress"],
                   help="completed = visible par les testeurs (défaut) ; "
                        "draft = préparé mais non diffusé")
    p.add_argument("--dry-run", action="store_true",
                   help="tout sauf le commit — valide sans rien publier")
    p.add_argument("--show-config", action="store_true",
                   help="affiche la configuration détectée et s'arrête "
                        "(aucun appel réseau)")
    p.add_argument("--list-tracks", action="store_true",
                   help="affiche les tracks existantes et leurs versionCodes")
    p.add_argument("--promote", type=int, metavar="VERSIONCODE",
                   help="ne rien uploader : (re)pointer la track sur un "
                        "versionCode déjà présent sur Play — sert à sortir une "
                        "release restée en draft, ou à promouvoir alpha → beta")
    p.add_argument("--allow-version-mismatch", action="store_true")
    p.add_argument("--yes-production", action="store_true",
                   help="requis pour viser la track production")
    args = p.parse_args()

    project = Project(args)
    if args.show_config:
        print(f"\n{project.describe()}\n")
        return
    if args.track == "production" and not args.yes_production:
        fail("Track production : ajoute --yes-production pour confirmer.")

    sess = session(project.credentials)
    if args.list_tracks:
        list_tracks(sess, project)
    else:
        publish(sess, project, args)


if __name__ == "__main__":
    main()
