/**
 * resolution.ts — La règle « l'outil ne devine pas » : décider, à partir de ce
 * que la base a rendu, si une ligne d'écriture désigne une carte, une édition
 * et une ligne possédée sans ambiguïté. Pur : aucune entrée-sortie.
 *
 * Elle tient lieu de la confirmation du §IV.8 de `CLAUDE.md` quand c'est un
 * assistant qui écrit : l'utilisateur ne confirme pas chaque carte, alors
 * l'outil n'écrit que ce qui ne laisse rien à choisir, et rend le reste.
 *
 * - **Nom** : seule une correspondance exacte (score 1 de `search_cards_bulk`,
 *   nom normalisé identique, dans n'importe quelle langue) désigne une carte.
 *   Une correspondance approchée revient en suggestion ; l'agent renvoie le
 *   nom exact s'il la retient.
 * - **Édition, à l'ajout** : désignée (extension + numéro), elle doit exister ;
 *   non désignée, elle est déduite quand la carte n'en a qu'une — la même règle
 *   que l'application — et sinon la carte va dans la pile à trier, comme une
 *   saisie au clavier sans édition. Une finition que l'édition n'a pas est
 *   refusée plutôt que corrigée.
 * - **Ligne, au retrait** : `remove_from_collection` vise une ligne précise
 *   (édition et finition). Quand la carte est possédée sur plusieurs lignes et
 *   que la demande ne départage pas, rien n'est retiré.
 */
import type { CarteTrouvee, Edition, LignePossedee } from './base.ts'

export type DecisionNom =
  | { genre: 'exacte'; carte: CarteTrouvee }
  | { genre: 'approchee'; suggestion: string }
  | { genre: 'introuvable' }

export type DecisionEdition =
  | { genre: 'edition'; edition: Edition }
  | { genre: 'pile' }
  | { genre: 'refus'; raison: string; choix?: string[] }

export type DecisionLigne =
  | { genre: 'ligne'; ligne: LignePossedee }
  | { genre: 'refus'; raison: string; choix?: string[] }

/** Ce qu'une ligne d'ajout précise de l'édition. */
export interface DemandeEdition {
  extension?: string
  numero?: string
  foil: boolean
}

/** Ce qu'une ligne de retrait précise de la ligne visée. */
export interface DemandeLigne {
  extension?: string
  numero?: string
  foil?: boolean
  pile?: boolean
}

/** Score de `search_cards_bulk` pour un nom normalisé identique. */
const SCORE_EXACT = 1

export function deciderNom(nom: string, trouvees: readonly CarteTrouvee[]): DecisionNom {
  const trouvee = trouvees.find((t) => t.query === nom)
  if (!trouvee) return { genre: 'introuvable' }
  if (trouvee.score >= SCORE_EXACT) return { genre: 'exacte', carte: trouvee }
  return { genre: 'approchee', suggestion: trouvee.matched_name }
}

export function libelleEdition(setCode: string | null, numero: string | null): string {
  if (!setCode || !numero) return 'pile à trier'
  return `${setCode.toUpperCase()} #${numero}`
}

function memeExtension(a: string | null, b: string): boolean {
  return (a ?? '').toLowerCase() === b.trim().toLowerCase()
}

function verifierFinition(edition: Edition, foil: boolean): DecisionEdition {
  if (foil && !edition.has_foil) {
    return { genre: 'refus', raison: "cette édition n'existe pas en foil" }
  }
  if (!foil && !edition.has_nonfoil) {
    return { genre: 'refus', raison: "cette édition n'existe qu'en foil : précisez foil: true" }
  }
  return { genre: 'edition', edition }
}

/**
 * @param candidates éditions de l'extension désignée (`card_printings`), ou
 *   `null` quand aucune extension n'est désignée.
 * @param unique l'édition de la carte si elle n'en a qu'une (`sole_editions`).
 */
export function deciderEdition(
  demande: DemandeEdition,
  candidates: readonly Edition[] | null,
  unique: Edition | undefined,
): DecisionEdition {
  const { extension, numero, foil } = demande
  if (Boolean(extension) !== Boolean(numero)) {
    return { genre: 'refus', raison: "l'extension et le numéro se donnent ensemble" }
  }
  if (extension && numero) {
    const dansExtension = (candidates ?? []).filter((e) => memeExtension(e.set_code, extension))
    const retenues = dansExtension.filter((e) => e.collector_number === numero.trim())
    if (retenues.length !== 1) {
      return {
        genre: 'refus',
        raison: `aucune édition ${libelleEdition(extension, numero)} pour cette carte`,
        choix: dansExtension.map((e) => libelleEdition(e.set_code, e.collector_number)),
      }
    }
    return verifierFinition(retenues[0], foil)
  }
  if (unique) return verifierFinition(unique, foil)
  return { genre: 'pile' }
}

function libelleLigne(l: LignePossedee): string {
  const finition = l.is_foil ? ' foil' : ''
  return `${libelleEdition(l.set_code, l.collector_number)}${finition} ×${l.quantity}`
}

export function deciderLigne(demande: DemandeLigne, lignes: readonly LignePossedee[]): DecisionLigne {
  if (lignes.length === 0) {
    return { genre: 'refus', raison: "vous n'en possédez aucun exemplaire" }
  }
  const retenues = lignes.filter((l) => {
    if (demande.pile && l.print_id !== null) return false
    if (demande.foil !== undefined && l.is_foil !== demande.foil) return false
    if (demande.extension && !memeExtension(l.set_code, demande.extension)) return false
    if (demande.numero && l.collector_number !== demande.numero.trim()) return false
    return true
  })
  if (retenues.length === 1) return { genre: 'ligne', ligne: retenues[0] }
  return {
    genre: 'refus',
    raison: retenues.length === 0
      ? 'aucun exemplaire possédé ne correspond à cette édition ou finition'
      : 'plusieurs éditions ou finitions possédées : précisez laquelle (extension et numéro, foil, ou pile: true)',
    choix: lignes.map(libelleLigne),
  }
}
