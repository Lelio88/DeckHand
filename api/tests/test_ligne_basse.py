"""Ce que `ligne_basse` reconnaît comme numéro et comme année dans une ligne lue."""

from app.measure.ligne_basse import (
    bottom_turn,
    parse_log,
    read_numbers,
    read_years,
    verdict,
)


def test_numero_et_total():
    assert read_numbers("TM & © 1993-2000 Wizards 247/350") == {247}


def test_numero_moderne_a_zeros():
    assert read_numbers("0348 C") == {348}
    assert read_numbers("U 0003 MSH • FR") == {3}


def test_force_et_endurance_ne_sont_pas_un_numero():
    # « 4/4 » est imprimé dans la même bande que le numéro.
    assert read_numbers("4/4") == set()
    assert read_numbers("12/12") == set()


def test_le_o_colle_a_un_chiffre_est_un_zero():
    # ML Kit rend souvent « C 0195 » en « CO195 ».
    assert read_numbers("CO195") == {195}
    assert read_numbers("M &O2026 Wizards") == set()  # 2026 n'est pas un numéro
    assert read_years("M &O2026 Wizards") == {2026}


def test_un_nombre_nu_n_est_pas_un_numero():
    # « 5 » ou « 2025 » seuls ne disent pas qu'on lit un numéro de collection.
    assert read_numbers("© 2025 Marvel 5") == set()


def test_annees_du_copyright():
    assert read_years("™ & © 1993-2001 Wizards of the Coast") == {1993, 2001}
    assert read_years("© 2025 Marvel") == {2025}
    assert read_years("0348 C MSH") == set()


def test_verdict():
    assert verdict({348}, 348) == "juste"
    # Deux numéros lus : l'application ne choisit pas, comme pour deux codes.
    assert verdict({348, 26}, 348) == "ambigu"
    assert verdict({12}, 348) == "faux"
    assert verdict(set(), 348) == "rien"


def test_le_bas_du_carton_est_le_sens_qui_porte_le_copyright():
    by_turn = {
        0: ["Levée de bouclier"],
        2: ["004", "MSH FI"],
        3: ["C0043", "TM&O2026 Wizards of the Coast", "MSH FR MICHAEL MACRAE"],
    }
    assert bottom_turn(by_turn) == 3
    assert bottom_turn({0: ["Levée"], 1: ["Vol"]}) is None


def test_parse_log():
    log = [
        "BANDE a.jpg tour=0 x1 1200x170 lignes=1",
        "BANDE a.jpg tour=0 x1 « 0348 C »",
        "BANDE a.jpg tour=2 r2 « © 2025 »",
        "BANDE b.jpg r sans-carte 1600x1204",
        "bruit",
    ]
    lines, missing = parse_log(log)
    assert lines == {("a.jpg", 0, "x", 1): ["0348 C"], ("a.jpg", 2, "r", 2): ["© 2025"]}
    assert missing == {("b.jpg", "r")}


def test_verdict_d_etalement():
    from app.measure.ligne_basse import spread_verdict

    truth = {43, 185, 22}
    assert spread_verdict({43}, truth) == "juste"
    assert spread_verdict({43, 22}, truth) == "ambigu"
    assert spread_verdict({44}, truth) == "faux"
    assert spread_verdict({43, 44}, truth) == "faux"
    assert spread_verdict(set(), truth) == "rien"
