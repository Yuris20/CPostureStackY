"""Package dei controlli (security, system, resource, backup).

Regola comune a TUTTI i moduli di questa cartella:

    CATEGORY = "Security"                 # una tra findings.CATEGORIES

    def run(conn, config) -> list[dict]

  - conn   : connessione OpenStack (vedi connection.py)
  - config : il modulo config.py (soglie e impostazioni)
  - ritorna: una lista di "finding" (segnalazioni)

Il formato del finding e i costruttori (make_finding, make_error_finding...) sono
definiti in cpostureStacky/findings.py. Avere sempre lo stesso formato permette a
report.py di non conoscere i dettagli dei singoli check.

common.py non è un check: contiene le funzioni condivise (perimetro "VM attiva",
lettura delle date di Cinder).
"""
