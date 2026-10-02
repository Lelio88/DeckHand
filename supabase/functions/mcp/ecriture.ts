/**
 * ecriture.ts — Les deux écritures de l'assistant, ajouter et retirer des
 * cartes, en lot : chaque ligne est résolue par la règle « l'outil ne devine
 * pas » (`resolution.ts`), puis écrite par la fonction SQL de l'application.
 *
 * Choix non évidents :
 * - **Une ligne refusée n'arrête pas le lot**, une panne non plus : chacune
 *   rend ce qui lui est arrivé, dans l'ordre de la demande. Comme le veut la
 *   doc du classeur, une écriture rend ce qu'elle a fait, non un état.
 * - **Une recherche pour tout le lot** (`search_cards_bulk`, noms dédoublonnés),
 *   puis les écritures une à une : deux lignes peuvent viser la même carte, et
 *   l'ordre de la demande doit rester celui des effets.
 * - **Aucune écriture ici ne touche au compte** : la base refuserait de toute
 *   façon (`20261002100000_garde_assistant.sql`).
 */
import type { McpServer } from '@modelcontextprotocol/server'
import { z } from 'zod'
import { type Base, type Jeu, JEUX } from './base.ts'
import { enJson } from './reponse.ts'
import { deciderEdition, deciderLigne, deciderNom, libelleEdition } from './resolution.ts'

export interface DemandeAjout {
  nom: string
  quantite: number
  extension?: string
  numero?: string
  langue?: string
  foil: boolean
}

export interface DemandeRetrait {
  nom: string
  quantite: number
  extension?: string
  numero?: string
  foil?: boolean
  pile?: boolean
}

export interface ResultatLigne {
  ligne: number
  nom: string
  statut: 'ajoute' | 'retire' | 'refuse'
  carte?: string
  edition?: string
  foil?: boolean
  quantite?: number
  total_possede?: number
  reste_sur_la_ligne?: number
  raison?: string
  suggestion?: string
  choix?: string[]
}

function messageDe(erreur: unknown): string {
  return erreur instanceof Error ? erreur.message : String(erreur)
}

function refusNom(ligne: number, nom: string, decision: ReturnType<typeof deciderNom>): ResultatLigne {
  if (decision.genre === 'approchee') {
    return {
      ligne,
      nom,
      statut: 'refuse',
      raison: "nom inexact : renvoyez le nom exact s'il s'agit bien de cette carte",
      suggestion: decision.suggestion,
    }
  }
  return { ligne, nom, statut: 'refuse', raison: 'carte introuvable dans ce jeu' }
}

async function chercher(base: Base, jeu: Jeu, noms: string[]) {
  return await base.chercherNoms([...new Set(noms)], jeu)
}

export async function ajouterCartes(base: Base, jeu: Jeu, demandes: readonly DemandeAjout[]): Promise<ResultatLigne[]> {
  const trouvees = await chercher(base, jeu, demandes.map((d) => d.nom))
  const exactes = trouvees.filter((t) => t.score >= 1).map((t) => t.oracle_id)
  const uniques = await base.editionsUniques([...new Set(exactes)])

  const resultats: ResultatLigne[] = []
  for (const [index, demande] of demandes.entries()) {
    const ligne = index + 1
    const nom = deciderNom(demande.nom, trouvees)
    if (nom.genre !== 'exacte') {
      resultats.push(refusNom(ligne, demande.nom, nom))
      continue
    }
    const carte = nom.carte
    try {
      const candidates = demande.extension
        ? await base.editionsDansExtension(carte.oracle_id, demande.extension, demande.langue)
        : null
      const edition = deciderEdition(demande, candidates, uniques.get(carte.oracle_id))
      if (edition.genre === 'refus') {
        resultats.push({
          ligne,
          nom: demande.nom,
          statut: 'refuse',
          carte: carte.name,
          raison: edition.raison,
          choix: edition.choix,
        })
        continue
      }
      const retenue = edition.genre === 'edition' ? edition.edition : null
      const total = await base.ajouter(carte.oracle_id, demande.quantite, retenue?.print_id ?? null, demande.foil)
      resultats.push({
        ligne,
        nom: demande.nom,
        statut: 'ajoute',
        carte: carte.name,
        edition: libelleEdition(retenue?.set_code ?? null, retenue?.collector_number ?? null),
        foil: demande.foil,
        quantite: demande.quantite,
        total_possede: total,
      })
    } catch (erreur) {
      resultats.push({ ligne, nom: demande.nom, statut: 'refuse', carte: carte.name, raison: messageDe(erreur) })
    }
  }
  return resultats
}

export async function retirerCartes(
  base: Base,
  jeu: Jeu,
  demandes: readonly DemandeRetrait[],
): Promise<ResultatLigne[]> {
  const trouvees = await chercher(base, jeu, demandes.map((d) => d.nom))

  const resultats: ResultatLigne[] = []
  for (const [index, demande] of demandes.entries()) {
    const ligne = index + 1
    const nom = deciderNom(demande.nom, trouvees)
    if (nom.genre !== 'exacte') {
      resultats.push(refusNom(ligne, demande.nom, nom))
      continue
    }
    const carte = nom.carte
    try {
      const lignes = await base.lignesPossedees(carte.oracle_id, carte.name, jeu)
      const decision = deciderLigne(demande, lignes)
      if (decision.genre === 'refus') {
        resultats.push({
          ligne,
          nom: demande.nom,
          statut: 'refuse',
          carte: carte.name,
          raison: decision.raison,
          choix: decision.choix,
        })
        continue
      }
      const visee = decision.ligne
      const retires = await base.retirer(carte.oracle_id, demande.quantite, visee.print_id, visee.is_foil)
      resultats.push({
        ligne,
        nom: demande.nom,
        statut: 'retire',
        carte: carte.name,
        edition: libelleEdition(visee.set_code, visee.collector_number),
        foil: visee.is_foil,
        quantite: retires,
        reste_sur_la_ligne: visee.quantity - retires,
      })
    } catch (erreur) {
      resultats.push({ ligne, nom: demande.nom, statut: 'refuse', carte: carte.name, raison: messageDe(erreur) })
    }
  }
  return resultats
}

// ── Enregistrement des outils ────────────────────────────────────────────────

const LOT_MAX = 100

const carteDemandee = {
  nom: z.string().min(1).max(200).describe("Nom exact de la carte, dans n'importe quelle langue"),
  quantite: z.number().int().min(1).max(999).default(1),
  extension: z.string().max(20).optional().describe("Code d'extension, avec numero"),
  numero: z.string().max(20).optional().describe('Numéro de collection, avec extension'),
}

export function enregistrerEcritures(server: McpServer, base: Base): void {
  server.registerTool('ajouter_cartes', {
    description: 'Ajoute des cartes à la collection, en lot. Un nom inexact est refusé avec une suggestion. ' +
      "Sans extension ni numéro, l'édition est déduite si la carte n'en a qu'une ; sinon la carte va dans " +
      "la pile à trier, où l'utilisateur précisera son édition. Chaque ligne rend ce qui a été fait.",
    inputSchema: z.object({
      jeu: z.enum(JEUX).default('magic'),
      cartes: z.array(z.object({
        ...carteDemandee,
        langue: z.string().max(8).optional().describe("Langue d'impression de l'édition désignée"),
        foil: z.boolean().default(false),
      })).min(1).max(LOT_MAX),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, async ({ jeu, cartes }) => enJson(await ajouterCartes(base, jeu, cartes)))

  server.registerTool('retirer_cartes', {
    description: "Retire des cartes de la collection, en lot. Faites confirmer la liste par l'utilisateur avant. " +
      "Quand une carte est possédée dans plusieurs éditions ou finitions, rien n'est retiré tant que la ligne " +
      'ne précise pas laquelle (extension et numéro, foil, ou pile: true pour la pile à trier).',
    inputSchema: z.object({
      jeu: z.enum(JEUX).default('magic'),
      cartes: z.array(z.object({
        ...carteDemandee,
        foil: z.boolean().optional(),
        pile: z.boolean().optional().describe('Viser les exemplaires sans édition précisée'),
      })).min(1).max(LOT_MAX),
    }),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  }, async ({ jeu, cartes }) => enJson(await retirerCartes(base, jeu, cartes)))
}
