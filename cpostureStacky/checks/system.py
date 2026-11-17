"""system.py - Controlli di sistema su Nova (stato delle VM).

Nova è il servizio che gestisce le macchine virtuali (chiamate "server").
Ogni VM ha uno "status": ACTIVE (accesa e funzionante), SHUTOFF (spenta),
ERROR (guasta), BUILD (in creazione), ecc.

Gravità assegnate:
  - HIGH   : ERROR / UNKNOWN (la VM è guasta o in stato non noto)
  - MEDIUM : stati transitori (BUILD, REBOOT...) oppure ACTIVE ma in realtà
             non accesa (incoerenza)
  - LOW    : VM spenta o in pausa (SHUTOFF, PAUSED, SUSPENDED)
  - INFO   : VM "shelved" (archiviata volontariamente) e riepilogo finale

READ-ONLY: usa solo conn.compute.servers() (lettura).
"""
from cpostureStacky import findings as findings_model
from cpostureStacky.checks import common

CATEGORY = "System"

# Tabella "stato della VM -> gravità".
# ACTIVE non è presente perché una VM sana non genera segnalazioni.
# Gli stati non elencati qui (BUILD, REBOOT, MIGRATING, RESCUE...) valgono MEDIUM.
STATUS_SEVERITY = {
    "ERROR": "HIGH",
    "UNKNOWN": "HIGH",
    "SHUTOFF": "LOW",
    "PAUSED": "LOW",
    "SUSPENDED": "LOW",
    "SHELVED": "INFO",
    "SHELVED_OFFLOADED": "INFO",
}

# Nova indica con il numero 1 che la VM è realmente in esecuzione (power state)
POWER_STATE_RUNNING = 1


def _check_server(server):
    """Valuta UNA VM. Restituisce un finding oppure None se è tutto ok."""
    resource_name = findings_model.describe_resource(server.name, server.id)
    # Se lo status manca lo trattiamo come UNKNOWN; upper() per uniformare
    status = (server.status or "UNKNOWN").upper()

    if status == common.ACTIVE_SERVER_STATUS:
        # Caso particolare: Nova dice ACTIVE ma lo "power state" dice che la
        # VM non gira davvero. getattr evita errori se il campo non esiste.
        power_state = getattr(server, "power_state", None)
        if power_state is not None and power_state != POWER_STATE_RUNNING:
            return findings_model.make_finding(
                CATEGORY, "MEDIUM", resource_name,
                "Stato ACTIVE ma la VM non risulta in esecuzione")
        return None  # VM sana: nessuna segnalazione

    # Per gli altri stati: gravità dalla tabella, MEDIUM se lo stato non c'è
    severity = STATUS_SEVERITY.get(status, "MEDIUM")
    message = f"VM in stato {status}"

    # Se la VM è in ERROR, Nova spesso spiega il motivo nel campo "fault":
    # lo aggiungiamo al messaggio per aiutare chi legge il report.
    fault = getattr(server, "fault", None)
    if status == "ERROR" and fault and fault.get("message"):
        message += f": {fault['message']}"
    return findings_model.make_finding(CATEGORY, severity, resource_name, message)


def run(conn, config):
    """Esegue i controlli di sistema e restituisce la lista di finding.

    Il parametro 'config' non serve a questo check (nessuna soglia configurabile)
    ma resta nella firma: tutti i moduli di checks/ hanno la stessa interfaccia
    run(conn, config), così main.py può trattarli in modo uniforme.
    """
    resource_findings = []
    try:
        servers = list(common.list_servers(conn).values())

        active_count = 0  # contatore delle VM attive, per il riepilogo
        for server in servers:
            if common.is_active_server(server):
                active_count += 1
            server_finding = _check_server(server)
            if server_finding:
                resource_findings.append(server_finding)

        # Finding INFO di riepilogo: utile anche quando non ci sono problemi
        resource_findings.append(findings_model.make_finding(
            CATEGORY, "INFO", "VM totali",
            f"{len(servers)} VM trovate, {active_count} in stato ACTIVE"))
    except Exception as exc:
        resource_findings.append(findings_model.make_error_finding(
            CATEGORY, "Controllo VM non completato", exc))
    return resource_findings
