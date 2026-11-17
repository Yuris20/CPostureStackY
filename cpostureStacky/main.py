"""main.py - Punto di ingresso del programma.

Questo file fa SOLO coordinamento: non contiene nessun controllo.
Il flusso è:
    1. crea la connessione a OpenStack          (connection.py)
    2. esegue i 4 moduli di controllo           (checks/*.py)
    3. genera il report e il riepilogo          (report.py)

Come si avvia (dalla cartella principale del progetto):
    python -m cpostureStacky.main

Codici di uscita:
    0 = analisi completa (anche se ha trovato problemi nel cloud)
    1 = connessione a OpenStack non riuscita
    2 = report generato, ma almeno un controllo NON si è completato
        (il report lo segnala con il badge ERRORE)
"""
import logging
import os
import sys

from cpostureStacky import config, findings as findings_model, report
from cpostureStacky.connection import get_connection
from cpostureStacky.checks import security, system, resource, backup

logger = logging.getLogger(__name__)

# Moduli da eseguire, in ordine. Per aggiungere un nuovo controllo basta
# creare un nuovo modulo con CATEGORY e run() e inserirlo in questa lista.
CHECK_MODULES = [security, system, resource, backup]

EXIT_CONNECTION_FAILED = 1
EXIT_CHECK_INCOMPLETE = 2


def main():
    # I messaggi diagnostici usano logging (default: solo avvisi); il livello si
    # alza con CPS_LOG_LEVEL=DEBUG. Il report in console resta su print: è l'output.
    logging.basicConfig(level=os.environ.get("CPS_LOG_LEVEL", "WARNING").upper(),
                        format="%(levelname)s %(name)s: %(message)s")

    # 1) Connessione
    try:
        connection = get_connection(config.CLOUD_NAME)
    except Exception as exc:
        print(f"Connessione a OpenStack non riuscita: {exc}")
        sys.exit(EXIT_CONNECTION_FAILED)

    # 2) Esecuzione dei controlli: ogni modulo restituisce la sua lista di
    #    finding e noi le uniamo in un'unica lista. I moduli gestiscono già i
    #    propri errori; il try qui è una rete di sicurezza che garantisce comunque
    #    la generazione del report se un modulo contenesse un bug.
    all_findings = []
    for check_module in CHECK_MODULES:
        try:
            all_findings += check_module.run(connection, config)
        except Exception as exc:
            all_findings.append(findings_model.make_error_finding(
                check_module.CATEGORY, "Controllo interrotto da un errore interno", exc))

    # 3) Output: report HTML + riepilogo nel terminale
    report_path = report.generate_html(all_findings, config.REPORTS_DIR, config.CLOUD_NAME)
    report.print_console(all_findings)
    print(f"Report HTML: {report_path}")

    incomplete_checks = [f for f in all_findings if findings_model.is_check_error(f)]
    if incomplete_checks:
        print(f"ATTENZIONE: {len(incomplete_checks)} controllo/i non completato/i: "
              "il report potrebbe essere parziale.")
        sys.exit(EXIT_CHECK_INCOMPLETE)


# Questo blocco fa partire main() solo quando il file è eseguito direttamente
# (python -m cpostureStacky.main), non quando viene importato da altri file.
if __name__ == "__main__":
    main()
