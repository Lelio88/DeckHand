/// Les correspondances rendues par le catalogue sur une photo de dix-sept
/// cartes posees a plat, telles que l'appareil les a obtenues.
///
/// **A quoi sert de figer des scores.** Le seuil qui separe la trouvaille du
/// hasard ne peut se regler qu'en observant de vraies correspondances : les
/// fabriquer reviendrait a choisir la reponse avant la question. Ces valeurs
/// viennent d'un scan reel — 141 lignes lues, 112 candidates apres filtrage,
/// 43 correspondances — et permettent de rejouer le seuil hors ligne, sans
/// appareil ni reseau.
///
/// La photo portait **dix-sept cartes**, comptees sur la table. C'est la verite
/// terrain : elle rend mesurable ce que l'application rate, et pas seulement ce
/// qu'elle trouve.
///
/// Compagnon de `measuredFan`, qui couvre le cas inverse — un eventail ou les
/// cartes se masquent — et sert de contre-epreuve a tout reglage tire d'ici.
library;

/// Une correspondance rendue par `search_cards_bulk`.
class MeasuredMatch {
  const MeasuredMatch(this.read, this.matched, this.score);

  /// Ligne telle que la reconnaissance de texte l'a lue.
  final String read;

  /// Nom de la carte que le catalogue a rapprochee de cette ligne.
  final String matched;

  final double score;
}

/// Nombre de cartes reellement posees sur la photo.
const int flatTruthCount = 17;

/// Les correspondances, de la meilleure a la pire.
const measuredFlatMatches = <MeasuredMatch>[
  MeasuredMatch("Renforts de quartier", "Renforts de quartier", 1.0000),
  MeasuredMatch("Agent Phil Coulson", "Agent Phil Coulson", 1.0000),
  MeasuredMatch("Brave Brawler", "Brave Brawler", 1.0000),
  MeasuredMatch("Agent d'Atlas", "Agent d'Atlas", 1.0000),
  MeasuredMatch("Commandos kree", "Kree Commandos", 1.0000),
  MeasuredMatch("Frappe de l'héliporteur", "Frappe de l'héliporteur", 1.0000),
  MeasuredMatch(
    "Captain Mar-Vell, Space-Born",
    "Captain Mar-Vell, Space-Born",
    1.0000,
  ),
  MeasuredMatch("Foule de vrais partisans", "Foule de vrais partisans", 1.0000),
  MeasuredMatch("Origine des Vengeurs", "Origine des Vengeurs", 1.0000),
  MeasuredMatch(
    "Okoye, cheffe des Dora Milaje",
    "Okoye, cheffe des Dora Milaje",
    1.0000,
  ),
  MeasuredMatch("Croisade de Murdock", "Croisade de Murdock", 1.0000),
  MeasuredMatch(
    "Oiseau Moqueur, agente de talent 3",
    "Oiseau Moqueur, agente de talent",
    0.9394,
  ),
  MeasuredMatch("Lancer", "Lancer de rat", 0.9100),
  MeasuredMatch("Héroine en forrmation", "Héroïne en formation", 0.8696),
  MeasuredMatch("Agent Maria Hil", "Agent Maria Hill", 0.8333),
  MeasuredMatch("Agent L3, Sharon Carter", "Agent 13, Sharon Carter", 0.7692),
  MeasuredMatch("éte", "Eternal Flame", 0.7323),
  MeasuredMatch("ure", "Ureni's Rebuff", 0.7300),
  MeasuredMatch("aron", "Aron, Benalia's Ruin", 0.7280),
  MeasuredMatch("Alennifer Walters", "Jennifer Walters", 0.6667),
  MeasuredMatch("Agents du S.H.LE.LD.", "Agents du S.H.I.E.L.D.", 0.6000),
  MeasuredMatch("Vieilance", "Vigilance", 0.5385),
  MeasuredMatch("coordinateura", "Coordinateur de décollage", 0.4615),
  MeasuredMatch("bad flash", "Flash Flood", 0.4286),
  MeasuredMatch("I Regard 2.", "Regard tueur", 0.4118),
  MeasuredMatch(
    "travail d'équipe, mettez un marqucur",
    "Transmetteur d'équipe",
    0.3902,
  ),
  MeasuredMatch("un rituel.", "Rituel de suie", 0.3889),
  MeasuredMatch("A noint de vie.", "Don de vie", 0.3889),
  MeasuredMatch("boML. No, pas", "Ne bougez pas !", 0.3684),
  MeasuredMatch("Sacrifies uprgs", "Sacrifice", 0.3684),
  MeasuredMatch(
    "S.HIELD, Üya des dizainer d'agents",
    "Agents du S.H.I.E.L.D.",
    0.3611,
  ),
  MeasuredMatch("engeurs", "Vengeur en-Dal", 0.3529),
  MeasuredMatch("s deux i la place.", "Place de l'arche", 0.3462),
  MeasuredMatch(
    "Vous controlez ont l'initiative,",
    "Saisir l'initiative",
    0.3421,
  ),
  MeasuredMatch("piochez u", "Lourde pioche", 0.3333),
  MeasuredMatch("sur le chettre", "Remettre sur la voie", 0.3333),
  MeasuredMatch("Sort a it lancé avcc le travail", "Le Sort ancestral", 0.3333),
  MeasuredMatch("haike", "Haine", 0.3333),
  MeasuredMatch(
    "Recyclage de terrain de base 2,dfse",
    "Don de terrain",
    0.3235,
  ),
  MeasuredMatch("tate, ch? Knuckle", "Knucklebone Witch", 0.3077),
  MeasuredMatch("blescés.", "Blessing", 0.3077),
  MeasuredMatch(
    "\"I came here to study the people of Earth,",
    "People of the Woods",
    0.3043,
  ),
  MeasuredMatch("Si vous ne le faites", "Ne faites aucun bruit", 0.3030),
];
