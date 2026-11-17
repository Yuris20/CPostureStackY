"""report.py - Generazione dei report.

Questo modulo si occupa SOLO di presentare i risultati:
  - generate_html(): crea il file HTML in reports/ (con filtri interattivi)
  - print_console(): stampa un riepilogo nel terminale
Non interroga OpenStack e non decide cosa sia un problema: riceve la lista di
finding già pronta dai moduli in checks/ (formato definito in findings.py).

L'HTML è costruito con semplici stringhe Python (nessuna libreria esterna).
I filtri funzionano con un piccolo JavaScript incluso nella pagina: il report
resta un unico file, apribile con qualsiasi browser senza server.

Sicurezza: ogni testo proveniente da OpenStack (nomi di risorse, messaggi di
errore...) è controllato dagli utenti del cloud e quindi NON è fidato. Passa
sempre da html.escape() prima di entrare nella pagina. Il JavaScript non usa
mai innerHTML con dati del report (solo textContent e attributi data-*).
"""
import html
import os
from datetime import datetime

from cpostureStacky import findings as findings_model
from cpostureStacky.findings import CATEGORIES, SEVERITIES

# Colore associato a ogni gravità. "OK" = categoria senza problemi,
# "ERROR" = categoria con almeno un controllo non completato.
COLORS = {"HIGH": "#d9534f", "MEDIUM": "#f0ad4e", "LOW": "#5bc0de",
          "INFO": "#8a8a8a", "OK": "#5cb85c", "ERROR": "#343a40"}

# Gravità che contano come "problemi" nei riquadri (l'INFO è solo informativo)
PROBLEM_SEVERITIES = SEVERITIES[:3]

# Stile della pagina (CSS), scritto una volta sola
CSS = """
body{font-family:Arial,sans-serif;margin:2em;color:#222;background:#fafafa}
h1{margin-bottom:0} .sub{color:#666;margin-top:4px}
.cards{display:flex;gap:1em;flex-wrap:wrap;margin:1.5em 0}
.card{background:#fff;border:1px solid #ddd;border-radius:6px;padding:1em;min-width:180px}
.card h3{margin:0 0 .5em 0}
.badge{color:#fff;padding:2px 8px;border-radius:10px;font-size:.85em;font-weight:bold}
table{border-collapse:collapse;width:100%;background:#fff}
th,td{border:1px solid #ddd;padding:6px 10px;text-align:left;font-size:.92em}
th{background:#eee}
.filters{display:flex;gap:1em;flex-wrap:wrap;align-items:end;margin:1.25em 0;
  padding:1em;background:#fff;border:1px solid #ddd;border-radius:8px}
.filter{display:flex;flex-direction:column;gap:.4em;flex:1;min-width:190px}
.filter label{font-size:.82em;font-weight:bold;color:#555}
.filters select,.filters button{font:inherit;padding:.65em .75em;border:1px solid #ccc;
  border-radius:5px;background:#fff;min-height:40px}
.filters select:focus,.filters button:focus{outline:2px solid #8ab4f8;outline-offset:1px}
.filters button{cursor:pointer;background:#f3f4f6;flex:0 0 auto}
.filters button:hover{background:#e7e9ed}
#results-count{color:#666;font-size:.9em;margin:.5em 0 .75em}
#empty-row td{text-align:center;color:#666;padding:1.25em}
@media(max-width:700px){
  body{margin:1em}.filters{align-items:stretch}.filter{width:100%}
  .filters button{width:100%}table{display:block;overflow-x:auto;white-space:normal}}
"""

# JavaScript dei filtri. È una normale stringa (non una f-string), quindi le
# graffe possono restare così. Ogni riga della tabella porta gli attributi
# data-severity e data-category; la risorsa si legge dalla terza cella.
# Il filtro nasconde le righe che non corrispondono (row.hidden) e aggiorna il
# contatore: non modifica in nessun modo i dati del report.
FILTER_JS = """
document.addEventListener('DOMContentLoaded', function () {
  const severity = document.getElementById('filter-severity');
  const category = document.getElementById('filter-category');
  const resource = document.getElementById('filter-resource');
  const reset = document.getElementById('reset-filters');
  const rows = Array.from(document.querySelectorAll('#findings-table tbody tr[data-severity]'));
  const emptyRow = document.getElementById('empty-row');
  const count = document.getElementById('results-count');

  function applyFilters() {
    let visible = 0;
    rows.forEach(function (row) {
      // Un filtro vuoto ("Tutte") accetta qualsiasi riga
      const ok = (!severity.value || row.dataset.severity === severity.value) &&
                 (!category.value || row.dataset.category === category.value) &&
                 (!resource.value || row.cells[2].textContent === resource.value);
      row.hidden = !ok;
      if (ok) visible += 1;
    });
    // Se nessuna riga corrisponde, mostra il messaggio "nessun risultato"
    emptyRow.hidden = visible !== 0;
    count.textContent = 'Visualizzati ' + visible + ' di ' + rows.length + ' risultati';
  }

  severity.addEventListener('change', applyFilters);
  category.addEventListener('change', applyFilters);
  resource.addEventListener('change', applyFilters);
  reset.addEventListener('click', function () {
    severity.value = '';
    category.value = '';
    resource.value = '';
    applyFilters();
  });
  applyFilters();
});
"""


def _badge(text, color):
    """Etichetta colorata (es. il 'HIGH' rosso).

    html.escape protegge la pagina: se il testo contenesse caratteri come
    < o >, non verrebbero interpretati come codice HTML. Il colore proviene
    sempre dal dizionario COLORS (mai da dati esterni).
    """
    return f'<span class="badge" style="background:{color}">{html.escape(text)}</span>'


def _severity_color(severity):
    """Colore di una gravità; per valori imprevisti usa quello dell'INFO."""
    return COLORS.get(severity, COLORS["INFO"])


def _category_card(findings, category):
    """Riquadro di riepilogo di una categoria (es. 'Security: HIGH, 2 HIGH').

    Priorità del badge:
      ERRORE se almeno un controllo della categoria non si è completato (così
      una categoria che non ha potuto essere analizzata non appare mai "OK");
      altrimenti la gravità peggiore tra i problemi; altrimenti OK.
    """
    category_findings = [f for f in findings if f["category"] == category]
    check_errors = [f for f in category_findings if findings_model.is_check_error(f)]
    # I finding INFO non sono problemi: non contano per lo stato della categoria
    issues = [f for f in category_findings if f["severity"] in PROBLEM_SEVERITIES]

    # Conteggio per gravità, es. "2 HIGH, 1 MEDIUM"
    counts = ", ".join(
        f"{sum(1 for f in issues if f['severity'] == severity)} {severity}"
        for severity in PROBLEM_SEVERITIES
        if any(f["severity"] == severity for f in issues))

    if check_errors:
        badge = _badge("ERRORE", COLORS["ERROR"])
        summary = "Controllo non completato: risultati parziali"
        if counts:
            summary += f" ({counts})"
    elif issues:
        # Gravità peggiore = quella con posizione più bassa in SEVERITIES
        worst = min((f["severity"] for f in issues), key=findings_model.severity_rank)
        badge, summary = _badge(worst, _severity_color(worst)), counts
    else:
        badge, summary = _badge("OK", COLORS["OK"]), "Nessun problema rilevato"
    return (f'<div class="card"><h3>{html.escape(category)}</h3>{badge}'
            f'<p>{html.escape(summary)}</p></div>')


def _options(values, first_label):
    """Costruisce le <option> di un menu a tendina.

    La prima voce ha valore vuoto e significa "nessun filtro".
    """
    options = [f'<option value="">{html.escape(first_label)}</option>']
    for value in values:
        options.append(f'<option value="{html.escape(value)}">{html.escape(value)}</option>')
    return "".join(options)


def _filter_box(label, select_id, options):
    """Un menu a tendina con la sua etichetta."""
    return (f'<div class="filter"><label for="{select_id}">{html.escape(label)}</label>'
            f'<select id="{select_id}">{options}</select></div>')


def _filters_html(findings):
    """Barra dei filtri: severità, categoria, risorsa e pulsante di reset."""
    # Le risorse sono quelle presenti nel report, senza doppioni e in ordine
    # alfabetico (senza distinguere maiuscole/minuscole). Le righe INFO di
    # riepilogo ("VM totali", "Volumi analizzati"...) non sono risorse da filtrare
    # e restano escluse dall'elenco (si trovano filtrando per severità INFO); i
    # controlli non completati invece restano, perché indicano un problema reale.
    resources = sorted({f["resource"] for f in findings
                        if f["severity"] != "INFO" or findings_model.is_check_error(f)},
                       key=str.lower)
    return (
        '<section class="filters" aria-label="Filtri del report">'
        + _filter_box("Severità", "filter-severity", _options(SEVERITIES, "Tutte"))
        + _filter_box("Categoria", "filter-category", _options(CATEGORIES, "Tutte"))
        + _filter_box("Risorsa", "filter-resource",
                      _options(resources, "Tutte le risorse"))
        + '<button id="reset-filters" type="button">Azzera filtri</button>'
        '</section>'
    )


def _table_html(findings):
    """Tabella dei finding, ordinata prima per gravità poi per categoria.

    Ogni riga ha data-severity e data-category: sono gli attributi che il
    JavaScript dei filtri usa per decidere quali righe mostrare.
    """
    ordered = sorted(findings, key=lambda f: (findings_model.severity_rank(f["severity"]),
                                              f["category"]))
    rows = []
    for finding in ordered:
        rows.append(
            f'<tr data-severity="{html.escape(finding["severity"])}" '
            f'data-category="{html.escape(finding["category"])}">'
            "<td>" + _badge(finding["severity"], _severity_color(finding["severity"])) + "</td>"
            f"<td>{html.escape(finding['category'])}</td>"
            f"<td>{html.escape(finding['resource'])}</td>"
            f"<td>{html.escape(finding['message'])}</td></tr>")
    # Riga nascosta, mostrata solo se i filtri non lasciano alcun risultato
    empty_row = ('<tr id="empty-row" hidden><td colspan="4">'
                 'Nessun risultato corrisponde ai filtri selezionati.</td></tr>')
    return ('<table id="findings-table"><thead><tr><th>Severità</th>'
            '<th>Categoria</th><th>Risorsa</th><th>Dettaglio</th></tr></thead>'
            "<tbody>" + "\n".join(rows) + empty_row + "</tbody></table>")


def generate_html(findings, reports_dir, cloud_name):
    """Scrive il report HTML in reports_dir e restituisce il percorso del file."""
    # astimezone(): data/ora locali CON fuso, così il report non è ambiguo
    now = datetime.now().astimezone()

    # Riquadri di riepilogo (uno per categoria)
    cards = "".join(_category_card(findings, category) for category in CATEGORIES)

    # Corpo della pagina: titolo, riquadri, filtri, contatore, tabella
    body = (
        "<h1>CPostureStackY - Cloud Posture Report</h1>"
        f'<p class="sub">Cloud: {html.escape(cloud_name)} | '
        f'Generato il {now:%d/%m/%Y %H:%M:%S %Z} | Analisi in sola lettura</p>'
        f'<div class="cards">{cards}</div>'
        + _filters_html(findings)
        + '<p id="results-count" aria-live="polite">Visualizzati '
          f'{len(findings)} di {len(findings)} risultati</p>'
        + _table_html(findings)
        + f"<script>{FILTER_JS}</script>"
    )

    # Pagina HTML completa (lang e viewport rendono la pagina adatta anche
    # agli schermi piccoli)
    page = ('<!DOCTYPE html><html lang="it"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            f"<title>CPostureStackY Report</title><style>{CSS}</style></head>"
            f"<body>{body}</body></html>")

    # Crea la cartella se non esiste e salva con un nome che contiene data e
    # ora, così ogni esecuzione produce un file diverso senza sovrascrivere.
    os.makedirs(reports_dir, exist_ok=True)
    report_path = os.path.join(reports_dir, f"report_{now:%Y%m%d_%H%M%S}.html")
    with open(report_path, "w", encoding="utf-8") as report_file:
        report_file.write(page)
    # Il report descrive le debolezze di sicurezza del cloud: leggibile solo
    # dal proprietario (0o600) invece dei permessi di default.
    os.chmod(report_path, 0o600)
    return report_path


def print_console(findings):
    """Stampa nel terminale i problemi (esclusi gli INFO) e un riepilogo.

    Fanno eccezione i controlli non completati: sono INFO per gravità, ma
    vengono stampati come ERRORE perché non devono passare inosservati.
    """
    for finding in findings:
        if findings_model.is_check_error(finding):
            print(f"[ERRORE] {finding['category']}: {finding['message']}")
        elif finding["severity"] != "INFO":
            print(f"[{finding['severity']}] {finding['category']} - "
                  f"{finding['resource']}: {finding['message']}")
    # Conteggio totale per gravità, es. "2 HIGH, 1 MEDIUM, 0 LOW, 1 INFO"
    summary = ", ".join(
        f"{sum(1 for f in findings if f['severity'] == severity)} {severity}"
        for severity in SEVERITIES)
    print(f"\nRiepilogo: {summary}")
