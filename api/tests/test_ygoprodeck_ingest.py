"""Tests de l'ingestion du catalogue Yu-Gi-Oh.

**Ce qu'ils protègent, ce sont des erreurs qui ne lèvent rien.** Une carte de
jeu vidéo entrée dans un catalogue de collection physique, une impression qui en
écrase une autre parce que la rareté ne fait pas partie de sa clé, un filtre de
recherche qui rend sept cents monstres au lieu des magies demandées : aucun de
ces défauts ne produit d'exception, tous produisent un écran plausible et faux.

Aucun réseau : les réponses de la source sont figées en fixtures, réduites aux
champs dont le module se sert.
"""

from __future__ import annotations

from app.ingestion.ygoprodeck_ingest import (
    catalogue_version,
    illustration_uuid,
    is_physical,
    oracle_uuid,
    print_uuid,
    type_line,
)

MAGIE = {
    "id": 80181649,
    "name": '"A Case for K9"',
    "type": "Spell Card",
    "humanReadableCardType": "Continuous Spell",
    "frameType": "spell",
    "race": "Continuous",
    "desc": "…",
    "card_sets": [
        {"set_name": "Justice Hunters", "set_code": "JUSH-EN040",
         "set_rarity": "Starlight Rare", "set_price": "0"},
        {"set_name": "Justice Hunters", "set_code": "JUSH-EN040",
         "set_rarity": "Super Rare", "set_price": "0"},
    ],
    "card_images": [{"id": 80181649, "image_url": "https://…/80181649.jpg"}],
}

SPELLCASTER = {
    "id": 46986414,
    "name": "Dark Magician",
    "type": "Normal Monster",
    "humanReadableCardType": "Normal Monster",
    "frameType": "normal",
    "race": "Spellcaster",
    "typeline": ["Spellcaster", "Normal"],
    "level": 7,
    "attribute": "DARK",
    "card_sets": [{"set_name": "Legend of Blue Eyes", "set_code": "LOB-EN005",
                   "set_rarity": "Ultra Rare", "set_price": "0"}],
    "card_images": [{"id": 46986414, "image_url": "https://…/46986414.jpg"}],
}

PENDULE = {
    "id": 16178681,
    "name": "Abyss Actor - Comic Relief",
    "type": "Pendulum Effect Monster",
    "humanReadableCardType": "Pendulum Effect Monster",
    "frameType": "effect_pendulum",
    "race": "Fiend",
    "typeline": ["Fiend", "Pendulum", "Effect"],
    "level": 1,
    "attribute": "DARK",
    "card_sets": [{"set_name": "Pendulum Evolution", "set_code": "PEVO-EN020",
                   "set_rarity": "Super Rare", "set_price": "0"}],
    "card_images": [{"id": 16178681, "image_url": "https://…/16178681.jpg"}],
}

SKILL = {
    "id": 300101001,
    "name": "Ancient Gear Fusion",
    "type": "Skill Card",
    "humanReadableCardType": "Skill Card",
    "frameType": "skill",
    "race": "Skill",
    "card_images": [{"id": 300101001, "image_url": "https://…/300101001.jpg"}],
}

JAMAIS_IMPRIMEE = {
    "id": 10000080,
    "name": "Obelisk the Tormentor (anime)",
    "type": "Effect Monster",
    "humanReadableCardType": "Effect Monster",
    "frameType": "effect",
    "race": "Divine-Beast",
    "card_images": [{"id": 10000080, "image_url": "https://…/10000080.jpg"}],
}


class TestCartesPhysiques:
    def test_une_carte_de_jeu_video_n_entre_pas(self):
        # Les 124 « Skill Cards » appartiennent à Duel Links. Elles n'ont même
        # pas d'illustration détourée — la source rend 404 — et n'ont rien à
        # faire dans une application qui ne parle que de carton.
        assert not is_physical(SKILL)

    def test_une_carte_jamais_imprimee_n_entre_pas(self):
        # 501 cartes n'ont aucune impression : elles n'existent que dans
        # l'anime. Les garder ferait espérer une carte qu'aucune boutique ne
        # vend et qu'aucun classeur ne rangera.
        assert not is_physical(JAMAIS_IMPRIMEE)

    def test_une_carte_ordinaire_entre(self):
        assert is_physical(MAGIE)
        assert is_physical(SPELLCASTER)


class TestLigneDeType:
    def test_le_filtre_des_magies_n_attrape_pas_les_magiciens(self):
        # **Le défaut que ce test existe pour empêcher.** Le filtre de recherche
        # est un `ILIKE '%kind%'` sur la ligne de type : chercher « Spell »
        # rendrait les quelque sept cents monstres de la famille Spellcaster en
        # plus des magies. L'utilisateur croirait le catalogue mal rangé.
        assert "spell card" in type_line(MAGIE).lower()
        assert "spell card" not in type_line(SPELLCASTER).lower()

    def test_un_monstre_repond_au_filtre_monstre(self):
        assert "monster" in type_line(SPELLCASTER).lower()

    def test_une_pendule_repond_aux_deux_filtres_qui_la_decrivent(self):
        # Une carte cumule ses types, et doit répondre à chacun : c'est la
        # lecture juste, déjà retenue pour Magic (« Artifact Creature »).
        ligne = type_line(PENDULE).lower()
        assert "monster" in ligne
        assert "pendulum" in ligne

    def test_rien_n_est_dit_deux_fois(self):
        # « Continuous Spell — Spell Card — Continuous » dit trois fois la même
        # chose. La déduplication porte sur la chaîne entière et non sur les
        # mots : découper casserait « Spell Card », qui est le vocabulaire
        # officiel et ce que cherche le filtre.
        assert type_line(MAGIE) == "Continuous Spell — Spell Card"


class TestIdentite:
    def test_le_passcode_donne_toujours_la_meme_cle(self):
        # Le passcode est imprimé sur la carte et ne change pas d'une
        # réimpression à l'autre. Une réingestion doit retomber sur la même
        # clé, faute de quoi les collections seraient orphelines.
        assert oracle_uuid(46986414) == oracle_uuid(46986414)
        assert oracle_uuid(46986414) != oracle_uuid(46986415)

    def test_deux_raretes_d_une_meme_extension_sont_deux_impressions(self):
        # **Mesuré : 44 287 impressions pour 38 297 codes distincts.** Sans la
        # rareté dans la clé, la Starlight Rare et la Super Rare de « Justice
        # Hunters » s'écraseraient l'une l'autre, et la collection perdrait la
        # version réellement possédée — celle qui porte la valeur.
        a, b = MAGIE["card_sets"]
        assert a["set_code"] == b["set_code"]
        assert print_uuid(a["set_code"], a["set_rarity"], MAGIE["id"]) != print_uuid(
            b["set_code"], b["set_rarity"], MAGIE["id"]
        )

    def test_une_illustration_partagee_n_est_hachee_qu_une_fois(self):
        assert illustration_uuid(46986414) == illustration_uuid(46986414)


class TestFraicheur:
    def test_un_catalogue_inchange_rend_la_meme_empreinte(self):
        # La source ne publie aucun numéro de version : à défaut, on hache ce
        # qu'on a reçu pour sauter une réécriture inutile.
        assert catalogue_version([MAGIE, SPELLCASTER]) == catalogue_version(
            [MAGIE, SPELLCASTER]
        )

    def test_une_impression_de_plus_change_l_empreinte(self):
        # Une carte qui gagne une réimpression doit relancer l'ingestion : c'est
        # le cas le plus fréquent, le catalogue s'enrichissant surtout par ses
        # rééditions.
        enrichie = dict(MAGIE)
        enrichie["card_sets"] = MAGIE["card_sets"] + [
            {"set_name": "Autre", "set_code": "XXXX-EN001", "set_rarity": "Common"}
        ]
        assert catalogue_version([MAGIE]) != catalogue_version([enrichie])
