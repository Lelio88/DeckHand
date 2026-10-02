/**
 * ecriture_test.ts — L'orchestration des écritures, sur une fausse base en
 * mémoire : ce qui est écrit, ce qui est refusé, et que rien ne s'écrit sur un
 * refus.
 *
 *   deno test supabase/functions/mcp
 */
import { assertEquals } from '@std/assert'
import type { Base, CarteTrouvee, Edition, LignePossedee } from './base.ts'
import { ajouterCartes, retirerCartes } from './ecriture.ts'

interface Appel {
  methode: 'ajouter' | 'retirer'
  oracleId: string
  quantite: number
  printId: string | null
  foil: boolean
}

/** Une base jouée en mémoire : un catalogue figé, et le journal des écritures. */
class FausseBase implements Base {
  appels: Appel[] = []
  recherches: string[][] = []
  echouerSur = new Set<string>()

  constructor(
    private readonly catalogue: Record<string, CarteTrouvee>,
    private readonly uniques: Map<string, Edition> = new Map(),
    private readonly extensions: Edition[] = [],
    private readonly lignes: LignePossedee[] = [],
  ) {}

  chercherNoms(noms: string[]) {
    this.recherches.push(noms)
    return Promise.resolve(
      noms.filter((n) => this.catalogue[n]).map((n) => ({ ...this.catalogue[n], query: n })),
    )
  }
  editionsUniques(oracleIds: string[]) {
    return Promise.resolve(new Map([...this.uniques].filter(([id]) => oracleIds.includes(id))))
  }
  editionsDansExtension() {
    return Promise.resolve(this.extensions)
  }
  lignesPossedees(oracleId: string) {
    return Promise.resolve(this.lignes.filter((l) => l.oracle_id === oracleId))
  }
  ajouter(oracleId: string, quantite: number, printId: string | null, foil: boolean) {
    if (this.echouerSur.has(oracleId)) return Promise.reject(new Error('panne simulée'))
    this.appels.push({ methode: 'ajouter', oracleId, quantite, printId, foil })
    return Promise.resolve(quantite + 1)
  }
  retirer(oracleId: string, quantite: number, printId: string | null, foil: boolean) {
    this.appels.push({ methode: 'retirer', oracleId, quantite, printId, foil })
    const ligne = this.lignes.find((l) => l.oracle_id === oracleId && l.print_id === printId)
    return Promise.resolve(Math.min(quantite, ligne?.quantity ?? 0))
  }
}

function carte(oracle: string, nom: string, score = 1): CarteTrouvee {
  return { query: nom, oracle_id: oracle, name: nom, matched_name: nom, score, owned: 0 }
}

const BOLT = carte('o-bolt', 'Lightning Bolt')
const SEULE: Edition = {
  print_id: 'p-seule',
  set_code: 'lea',
  collector_number: '1',
  lang: 'en',
  has_foil: false,
  has_nonfoil: true,
}

Deno.test('ajout : sans édition désignée et plusieurs possibles, la carte va dans la pile', async () => {
  const base = new FausseBase({ 'Lightning Bolt': BOLT })
  const [r] = await ajouterCartes(base, 'magic', [{ nom: 'Lightning Bolt', quantite: 2, foil: false }])
  assertEquals(r.statut, 'ajoute')
  assertEquals(r.edition, 'pile à trier')
  assertEquals(base.appels, [{ methode: 'ajouter', oracleId: 'o-bolt', quantite: 2, printId: null, foil: false }])
})

Deno.test('ajout : une édition unique est déduite', async () => {
  const base = new FausseBase({ 'Lightning Bolt': BOLT }, new Map([['o-bolt', SEULE]]))
  const [r] = await ajouterCartes(base, 'magic', [{ nom: 'Lightning Bolt', quantite: 1, foil: false }])
  assertEquals(r.edition, 'LEA #1')
  assertEquals(base.appels[0].printId, 'p-seule')
})

Deno.test("ajout : un nom approché ne s'écrit pas et revient en suggestion", async () => {
  const base = new FausseBase({ 'lightnin bolt': carte('o-bolt', 'Lightning Bolt', 0.8) })
  const [r] = await ajouterCartes(base, 'magic', [{ nom: 'lightnin bolt', quantite: 1, foil: false }])
  assertEquals(r.statut, 'refuse')
  assertEquals(r.suggestion, 'Lightning Bolt')
  assertEquals(base.appels, [])
})

Deno.test('ajout : un lot garde son ordre, continue après un refus et après une panne', async () => {
  const base = new FausseBase({
    'Lightning Bolt': BOLT,
    'Counterspell': carte('o-counter', 'Counterspell'),
    'Brainstorm': carte('o-brain', 'Brainstorm'),
  })
  base.echouerSur.add('o-counter')
  const resultats = await ajouterCartes(base, 'magic', [
    { nom: 'Carte imaginaire', quantite: 1, foil: false },
    { nom: 'Counterspell', quantite: 1, foil: false },
    { nom: 'Brainstorm', quantite: 1, foil: false },
    { nom: 'Lightning Bolt', quantite: 1, foil: false },
  ])
  assertEquals(resultats.map((r) => [r.ligne, r.statut]), [
    [1, 'refuse'],
    [2, 'refuse'],
    [3, 'ajoute'],
    [4, 'ajoute'],
  ])
  assertEquals(resultats[1].raison, 'panne simulée')
  // Une seule recherche pour tout le lot, chaque nom une fois.
  assertEquals(base.recherches.length, 1)
})

Deno.test('retrait : une seule ligne possédée est visée, le reste est dit', async () => {
  const ligne: LignePossedee = {
    oracle_id: 'o-bolt',
    print_id: 'p-1',
    is_foil: false,
    set_code: 'm11',
    collector_number: '149',
    quantity: 3,
  }
  const base = new FausseBase({ 'Lightning Bolt': BOLT }, new Map(), [], [ligne])
  const [r] = await retirerCartes(base, 'magic', [{ nom: 'Lightning Bolt', quantite: 2 }])
  assertEquals(r.statut, 'retire')
  assertEquals(r.quantite, 2)
  assertEquals(r.reste_sur_la_ligne, 1)
  assertEquals(base.appels[0].printId, 'p-1')
})

Deno.test("retrait : plusieurs lignes et rien pour départager, rien n'est retiré", async () => {
  const base = new FausseBase({ 'Lightning Bolt': BOLT }, new Map(), [], [
    { oracle_id: 'o-bolt', print_id: 'p-1', is_foil: false, set_code: 'm11', collector_number: '149', quantity: 1 },
    { oracle_id: 'o-bolt', print_id: null, is_foil: false, set_code: null, collector_number: null, quantity: 1 },
  ])
  const [r] = await retirerCartes(base, 'magic', [{ nom: 'Lightning Bolt', quantite: 1 }])
  assertEquals(r.statut, 'refuse')
  assertEquals(r.choix, ['M11 #149 ×1', 'pile à trier ×1'])
  assertEquals(base.appels, [])
})
