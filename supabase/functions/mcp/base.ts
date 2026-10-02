/**
 * base.ts — Le seul passage du serveur MCP vers la base, pour les écritures :
 * une interface (`Base`) que les outils d'écriture consomment, et son
 * implémentation sur le client Supabase de l'utilisateur.
 *
 * Choix non évidents :
 * - **Une interface plutôt que le client direct**, pour que l'orchestration
 *   des écritures (`ecriture.ts`) s'éprouve sur un faux, sans réseau (doctrine
 *   du projet : fakes plutôt que mocks). Les outils de lecture, qui ne font
 *   que transmettre une fonction SQL, appellent le client directement.
 * - **Rien n'est calculé ici** : chaque méthode est une fonction SQL existante
 *   (`search_cards_bulk`, `sole_editions`, `card_printings`, `my_collection`,
 *   `add_to_collection`, `remove_from_collection`), appelée avec le jeton de
 *   l'utilisateur. La RLS et la garde de l'assistant s'appliquent donc
 *   d'elles-mêmes ; le calcul reste dans la base.
 *
 * Invariant : le client passé à `baseSupabase` est celui que `withSupabase`
 * borne à l'utilisateur, jamais un client administrateur.
 */
import type { SupabaseClient } from '@supabase/supabase-js'
import { siErreur } from './reponse.ts'

/** Les jeux du catalogue, tels que les contraint `cards.game`. */
export const JEUX = [
  'magic',
  'riftbound',
  'yugioh',
  'pokemon',
  'wankul',
  'swu',
  'onepiece',
  'lorcana',
] as const
export type Jeu = typeof JEUX[number]

/** Une ligne de `search_cards_bulk` : la meilleure carte pour un nom cherché. */
export interface CarteTrouvee {
  query: string
  oracle_id: string
  name: string
  matched_name: string
  score: number
  owned: number
}

/** Une édition (extension + numéro), dans une langue d'impression. */
export interface Edition {
  print_id: string
  set_code: string
  collector_number: string
  lang: string
  has_foil: boolean
  has_nonfoil: boolean
}

/** Une ligne possédée : une carte, dans une édition (ou aucune) et une finition. */
export interface LignePossedee {
  oracle_id: string
  print_id: string | null
  is_foil: boolean
  set_code: string | null
  collector_number: string | null
  quantity: number
}

export interface Base {
  /** `search_cards_bulk` : une ligne par nom trouvé, aucune pour un nom introuvable. */
  chercherNoms(noms: string[], jeu: Jeu): Promise<CarteTrouvee[]>
  /** `sole_editions` : l'édition des seules cartes qui n'en ont qu'une. */
  editionsUniques(oracleIds: string[]): Promise<Map<string, Edition>>
  /** `card_printings` : les éditions d'une carte dans une extension. */
  editionsDansExtension(oracleId: string, extension: string, langue?: string): Promise<Edition[]>
  /** `my_collection` : les lignes possédées d'une carte. */
  lignesPossedees(oracleId: string, nom: string, jeu: Jeu): Promise<LignePossedee[]>
  /** `add_to_collection` : rend le total possédé de la carte, toutes éditions. */
  ajouter(oracleId: string, quantite: number, printId: string | null, foil: boolean): Promise<number>
  /** `remove_from_collection` : rend le nombre d'exemplaires retirés. */
  retirer(oracleId: string, quantite: number, printId: string | null, foil: boolean): Promise<number>
}

/** Plafond de `my_collection` pour retrouver les lignes d'une seule carte. */
const LIGNES_MAX = 200

export function baseSupabase(client: SupabaseClient): Base {
  return {
    async chercherNoms(noms, jeu) {
      const { data, error } = await client.rpc('search_cards_bulk', { p_names: noms, p_game: jeu })
      siErreur('search_cards_bulk', error)
      return (data ?? []) as CarteTrouvee[]
    },

    async editionsUniques(oracleIds) {
      const uniques = new Map<string, Edition>()
      if (oracleIds.length === 0) return uniques
      const { data, error } = await client.rpc('sole_editions', { p_oracle_ids: oracleIds })
      siErreur('sole_editions', error)
      for (const ligne of (data ?? []) as (Edition & { oracle_id: string })[]) {
        uniques.set(ligne.oracle_id, ligne)
      }
      return uniques
    },

    async editionsDansExtension(oracleId, extension, langue) {
      const { data, error } = await client.rpc('card_printings', {
        p_oracle_id: oracleId,
        p_query: extension,
        p_lang: langue ?? null,
        p_limit: 60,
      })
      siErreur('card_printings', error)
      return (data ?? []) as Edition[]
    },

    async lignesPossedees(oracleId, nom, jeu) {
      const { data, error } = await client.rpc('my_collection', {
        p_query: nom,
        p_game: jeu,
        p_limit: LIGNES_MAX,
      })
      siErreur('my_collection', error)
      return ((data ?? []) as LignePossedee[]).filter((l) => l.oracle_id === oracleId)
    },

    async ajouter(oracleId, quantite, printId, foil) {
      const { data, error } = await client.rpc('add_to_collection', {
        p_oracle_id: oracleId,
        p_quantity: quantite,
        p_print_id: printId,
        p_is_foil: foil,
      })
      siErreur('add_to_collection', error)
      return data as number
    },

    async retirer(oracleId, quantite, printId, foil) {
      const { data, error } = await client.rpc('remove_from_collection', {
        p_oracle_id: oracleId,
        p_quantity: quantite,
        p_print_id: printId,
        p_is_foil: foil,
      })
      siErreur('remove_from_collection', error)
      return data as number
    },
  }
}
