"""Connecteurs d'ingestion des sources externes.

Un module par source, isolé derrière une interface stable : les sources n'ont pas les
mêmes garanties de pérennité (Scryfall et TopDeck.gg sont contractuels, Archidekt est
toléré, EDHTop16 n'a pas de conditions formalisées). Le cœur du produit ne doit jamais
dépendre directement de l'une d'elles.
"""
