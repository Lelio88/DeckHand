"""Génère le jingle de l'écran d'introduction de DeckHand.

**Un script plutôt qu'un fichier déposé**, pour la même raison que
`api/make_store_assets.py` : un son se refait — une note qui traîne, un volume
qui gêne sur haut-parleur de téléphone, une animation dont on déplace une
battue. Le script le régénère à l'identique ; un WAV figé oblige à rouvrir un
éditeur et à retrouver les valeurs de départ.

**Le rythme est celui de l'animation, pas l'inverse.** Une note par geste :
les trois cartes qui se posent, le retournement de celle du milieu, l'éventail
qui se referme sur la pose du logo, et le mot qui monte. Déplacer une battue ici
sans la déplacer dans l'intro casse la synchronisation, et cela ne s'entend
qu'à l'oreille — d'où [BATTUES], seule source des deux côtés.

**Six notes, comme DewDrop, et c'est délibéré.** Les deux applications partagent
une grammaire : une intro d'environ 2,2 s, six notes, le logo qui apparaît
dedans. Ce qui change est la couleur. DewDrop monte un arpège de do majeur en
onde carrée 8-bit — cristallin, aérien. DeckHand descend sur du bois : sol
mixolydien, corde pincée, septième mineure. Trois autres pistes ont été
comparées à l'écoute avant de retenir celle-ci — ré mineur boisé, un contour
descendant « cartes qu'on pose », et l'arpège de DewDrop sur un autre timbre.
Le mixolydien a été choisi pour son caractère : majeur sans être sage, ce qui
convient à un jeu de cartes mieux qu'une berceuse.

**Le timbre n'est pas un carré.** C'est une pile d'harmoniques à décroissance
rapide — une corde pincée — dont les rangs élevés s'éteignent plus vite que le
fondamental. C'est exactement ce qui sépare une corde d'un orgue, et c'est
pourquoi les coefficients de [corde] ne sont pas un réglage mais une
description : les toucher change l'instrument, pas le volume.

Usage :

    cd api && .venv/Scripts/python ../tools/sounds/gen_intro_jingle.py

Écrit `app/assets/audio/deckhand_intro.mp3` (et le WAV intermédiaire si ffmpeg
manque). Dépend de `numpy`, déjà présent dans l'environnement de `api/`.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100

RACINE = Path(__file__).resolve().parents[2]
SORTIE = RACINE / "app" / "assets" / "audio"
NOM = "deckhand_intro"

#: Les six battues de l'animation, en secondes depuis la première carte posée.
#:
#: **Jumelle de `IntroTiming` côté Dart.** L'intro démarre le son à 0,2 s ; ces
#: valeurs sont donc relatives à cet instant, et non au début de l'écran.
BATTUES = [0.00, 0.30, 0.60, 0.90, 1.10, 1.40]

#: Durée de chaque note. La dernière tient pendant que le mot monte en fondu.
DUREES = [0.28, 0.28, 0.28, 0.22, 0.26, 0.90]

#: Sol mixolydien. Le `F5` en quatrième position est la septième mineure : c'est
#: elle qui empêche l'arpège de sonner comme une comptine en sol majeur.
MELODIE = ["G4", "B4", "D5", "F5", "G5", "D6"]

#: Voix d'accompagnement, une tierce ou une sixte sous la mélodie selon la note.
#: Suivre la mélodie en parallèle strict donnerait un orgue ; alterner donne un
#: mouvement.
HARMONIE = ["D4", "G4", "B4", "D5", "B4", "G5"]

#: Basse triangle, tenue sous les six notes. Sans elle l'arpège flotte.
BASSE = "G2"

#: Volumes calés à l'oreille sur les quatre variantes comparées. La mélodie
#: porte, l'harmonie soutient, le souffle et la basse ne s'entendent pas
#: séparément — ils s'entendent quand on les retire.
VOL_MELODIE, VOL_HARMONIE, VOL_SOUFFLE, VOL_BASSE = 0.100, 0.055, 0.018, 0.075

#: Au-delà, le crépitement des harmoniques devient sifflant au casque. C'est le
#: même garde-fou que `PageTurnVoice.softness` pour le froissement des pages.
COUPURE_HZ = 5200

DEMI_TONS = {
    "C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5,
    "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11,
}


def hauteur(nom: str) -> float:
    """Fréquence d'une note nommée. `A4` vaut 440 Hz."""
    note, octave = nom[:-1], int(nom[-1])
    return 440.0 * 2 ** ((DEMI_TONS[note] + 12 * (octave - 4) - 9) / 12)


def corde(freq: float, duree: float, chaleur: float = 1.0) -> np.ndarray:
    """Une corde pincée : harmoniques dont les rangs hauts s'éteignent d'abord.

    [chaleur] allonge la décroissance — au-dessus de 1 la note traîne, ce qui
    convient à la basse et à l'harmonie, jamais à la mélodie.
    """
    t = np.arange(int(duree * SR)) / SR
    voix = np.zeros_like(t)
    # Le 2e et le 3e rang portent le bois ; au-delà, on ne veut qu'une trace.
    for rang, poids in enumerate([1.0, 0.42, 0.22, 0.10, 0.05], start=1):
        if freq * rang > SR / 2:
            break
        declin = np.exp(-t * (3.2 + rang * 2.1) / chaleur)
        voix += poids * declin * np.sin(2 * np.pi * freq * rang * t + rang * 0.7)
    attaque = np.clip(t / 0.004, 0, 1)
    return voix * attaque * np.exp(-t * 1.4 / chaleur)


def souffle(freq: float, duree: float) -> np.ndarray:
    """Un sous-corps sinus très doux : le feutre sous la corde."""
    t = np.arange(int(duree * SR)) / SR
    return np.sin(2 * np.pi * freq * t) * np.exp(-t * 2.2) * np.clip(t / 0.01, 0, 1)


def pose(buffer: np.ndarray, voix: np.ndarray, debut: float, volume: float) -> None:
    """Mélange [voix] dans [buffer] à partir de [debut]. Déborde sans lever."""
    i = int(debut * SR)
    fin = min(len(buffer), i + len(voix))
    if fin > i:
        buffer[i:fin] += volume * voix[: fin - i]


def reverb(x: np.ndarray, humide: float = 0.20) -> np.ndarray:
    """Réverbération de Schroeder légère, en peignes à rétroaction.

    Sans elle, six notes sèches sonnent comme un test de synthèse. Avec trop,
    l'intro sonne comme une cathédrale — 0,20 est le point où l'on entend une
    pièce, pas un effet.
    """
    sortie = x.copy()
    for retard_s, retour in ((0.0297, 0.80), (0.0371, 0.77), (0.0411, 0.74), (0.0437, 0.71)):
        d = int(retard_s * SR)
        peigne = x.copy()
        for i in range(d, len(peigne)):
            peigne[i] += retour * peigne[i - d]
        sortie += peigne * humide * 0.25
    return sortie


def passe_bas(x: np.ndarray, coupure: float = COUPURE_HZ) -> np.ndarray:
    """Un pôle, pour ôter le sifflant des harmoniques hautes."""
    a = np.exp(-2 * np.pi * coupure / SR)
    y = np.zeros_like(x)
    accumule = 0.0
    for i, v in enumerate(x):
        accumule = (1 - a) * v + a * accumule
        y[i] = accumule
    return y


def construire() -> np.ndarray:
    """Le jingle entier, normalisé à −1,4 dBFS."""
    total = BATTUES[-1] + DUREES[-1] + 0.8
    buffer = np.zeros(int(SR * total))

    for note, harm, debut, duree in zip(MELODIE, HARMONIE, BATTUES, DUREES):
        pose(buffer, corde(hauteur(note), duree), debut, VOL_MELODIE)
        pose(buffer, corde(hauteur(harm), duree, chaleur=1.3), debut, VOL_HARMONIE)
        pose(buffer, souffle(hauteur(note), duree * 0.6), debut, VOL_SOUFFLE)

    # La basse entre avec la première carte et tient jusqu'au mot.
    pose(buffer, corde(hauteur(BASSE), 1.9, chaleur=2.6), 0.0, VOL_BASSE)

    buffer = passe_bas(reverb(buffer))
    crete = float(np.max(np.abs(buffer)))
    return buffer * (0.85 / max(crete, 1e-6))


def ecrire_wav(chemin: Path, echantillons: np.ndarray) -> None:
    with wave.open(str(chemin), "w") as sortie:
        sortie.setnchannels(1)
        sortie.setsampwidth(2)
        sortie.setframerate(SR)
        borne = np.clip(echantillons, -1.0, 1.0)
        sortie.writeframes((borne * 32767).astype("<i2").tobytes())


def main() -> int:
    SORTIE.mkdir(parents=True, exist_ok=True)
    wav = SORTIE / f"{NOM}.wav"
    ecrire_wav(wav, construire())

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        print(f"ffmpeg absent — le WAV reste seul : {wav} ({wav.stat().st_size // 1024} Kio)")
        return 0

    mp3 = SORTIE / f"{NOM}.mp3"
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(wav), "-b:a", "128k", str(mp3)],
        check=True,
    )
    # **Le WAV est un intermédiaire, pas un livrable.** Le garder ferait entrer
    # 270 Kio inutiles dans l'APK — pour un son que personne ne compare.
    wav.unlink()
    print(f"écrit : {mp3.relative_to(RACINE)} ({mp3.stat().st_size // 1024} Kio)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
