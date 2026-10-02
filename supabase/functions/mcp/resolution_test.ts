/**
 * resolution_test.ts — La règle « l'outil ne devine pas », sans réseau.
 *
 *   deno test supabase/functions/mcp
 */
import { assertEquals } from '@std/assert'
import type { CarteTrouvee, Edition, LignePossedee } from './base.ts'
import { deciderEdition, deciderLigne, deciderNom } from './resolution.ts'

const BOLT: CarteTrouvee = {
  query: 'lightning bolt',
  oracle_id: 'o-bolt',
  name: 'Lightning Bolt',
  matched_name: 'Lightning Bolt',
  score: 1,
  owned: 0,
}

function edition(partiel: Partial<Edition>): Edition {
  return {
    print_id: 'p-1',
    set_code: 'm11',
    collector_number: '149',
    lang: 'en',
    has_foil: true,
    has_nonfoil: true,
    ...partiel,
  }
}

function ligne(partiel: Partial<LignePossedee>): LignePossedee {
  return {
    oracle_id: 'o-bolt',
    print_id: 'p-1',
    is_foil: false,
    set_code: 'm11',
    collector_number: '149',
    quantity: 2,
    ...partiel,
  }
}

// ── Le nom ──────────────────────────────────────────────────────────────────

Deno.test('un nom trouvé exactement désigne la carte', () => {
  assertEquals(deciderNom('lightning bolt', [BOLT]), { genre: 'exacte', carte: BOLT })
})

Deno.test('un nom approché ne désigne rien : il revient en suggestion', () => {
  const approche = { ...BOLT, query: 'lightnin bolt', score: 0.82 }
  assertEquals(deciderNom('lightnin bolt', [approche]), {
    genre: 'approchee',
    suggestion: 'Lightning Bolt',
  })
})

Deno.test('un nom sans résultat est introuvable', () => {
  assertEquals(deciderNom('carte imaginaire', [BOLT]), { genre: 'introuvable' })
})

// ── L'édition, à l'ajout ────────────────────────────────────────────────────

Deno.test('une édition désignée et existante est retenue', () => {
  const m11 = edition({})
  assertEquals(
    deciderEdition({ extension: 'M11', numero: '149', foil: false }, [m11], undefined),
    { genre: 'edition', edition: m11 },
  )
})

Deno.test("une édition désignée mais inconnue est refusée, avec les numéros de l'extension", () => {
  const decision = deciderEdition(
    { extension: 'm11', numero: '999', foil: false },
    [edition({ collector_number: '149' }), edition({ print_id: 'p-2', collector_number: '150' })],
    undefined,
  )
  assertEquals(decision.genre, 'refus')
  if (decision.genre === 'refus') assertEquals(decision.choix, ['M11 #149', 'M11 #150'])
})

Deno.test('une extension sans numéro est refusée', () => {
  assertEquals(
    deciderEdition({ extension: 'm11', foil: false }, [], undefined).genre,
    'refus',
  )
})

Deno.test('sans édition désignée, une édition unique est déduite', () => {
  const seule = edition({ print_id: 'p-seule' })
  assertEquals(
    deciderEdition({ foil: false }, null, seule),
    { genre: 'edition', edition: seule },
  )
})

Deno.test('sans édition désignée et plusieurs possibles, la carte va dans la pile à trier', () => {
  assertEquals(deciderEdition({ foil: false }, null, undefined), { genre: 'pile' })
})

Deno.test("une finition que l'édition n'a pas est refusée", () => {
  const sansFoil = edition({ has_foil: false })
  assertEquals(deciderEdition({ foil: true }, null, sansFoil).genre, 'refus')
  const foilSeulement = edition({ has_nonfoil: false })
  assertEquals(deciderEdition({ foil: false }, null, foilSeulement).genre, 'refus')
})

// ── La ligne, au retrait ────────────────────────────────────────────────────

Deno.test('une seule ligne possédée : le retrait la vise', () => {
  const seule = ligne({})
  assertEquals(deciderLigne({}, [seule]), { genre: 'ligne', ligne: seule })
})

Deno.test('aucune ligne possédée : refus', () => {
  assertEquals(deciderLigne({}, []).genre, 'refus')
})

Deno.test('plusieurs lignes et rien pour départager : refus avec les lignes', () => {
  const decision = deciderLigne({}, [
    ligne({}),
    ligne({ print_id: 'p-foil', is_foil: true }),
    ligne({ print_id: null, set_code: null, collector_number: null, quantity: 1 }),
  ])
  assertEquals(decision.genre, 'refus')
  if (decision.genre === 'refus') {
    assertEquals(decision.choix, ['M11 #149 ×2', 'M11 #149 foil ×2', 'pile à trier ×1'])
  }
})

Deno.test("l'édition et la finition désignées départagent", () => {
  const foil = ligne({ print_id: 'p-foil', is_foil: true })
  assertEquals(
    deciderLigne({ extension: 'M11', numero: '149', foil: true }, [ligne({}), foil]),
    { genre: 'ligne', ligne: foil },
  )
})

Deno.test('la pile à trier se désigne par pile: true', () => {
  const pile = ligne({ print_id: null, set_code: null, collector_number: null })
  assertEquals(
    deciderLigne({ pile: true }, [ligne({}), pile]),
    { genre: 'ligne', ligne: pile },
  )
})
