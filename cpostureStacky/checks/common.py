"""common.py - Funzioni condivise da più moduli di controllo.

Contiene le definizioni che devono essere IDENTICHE in security.py e backup.py,
in particolare il concetto di "VM attiva": averlo in un solo punto garantisce che
i due moduli lavorino sullo stesso perimetro.
"""
from datetime import datetime, timezone

# Una VM è considerata "attiva" (workload in esecuzione) solo se Nova la
# riporta in questo stato. VM spente, in errore o in pausa non contano:
# non espongono né contengono dati in uso in questo momento.
ACTIVE_SERVER_STATUS = "ACTIVE"


def list_servers(conn):
    """Restituisce {id_vm: oggetto server} di TUTTE le VM del cloud.

    API OpenStack: Nova, elenco dei server con dettagli.
    all_projects=True: servono le VM di TUTTI i progetti, non solo quelle del
    progetto dell'utente admin (richiede credenziali amministrative).
    Eventuali eccezioni dell'SDK NON vengono gestite qui: le gestisce il check
    chiamante, che sa come segnalarle nel report.
    """
    servers = conn.compute.servers(details=True, all_projects=True)
    return {server.id: server for server in servers}


def is_active_server(server):
    """True se la VM è in esecuzione secondo Nova (status ACTIVE)."""
    return (server.status or "").upper() == ACTIVE_SERVER_STATUS


def parse_cinder_date(date_text):
    """Converte la data testuale restituita da Cinder in datetime con fuso UTC.

    Esempi di input: '2026-11-10T10:00:00.000000' oppure '...Z'.
    Cinder fornisce date in UTC ma spesso senza indicare il fuso: lo aggiungiamo
    per poterle confrontare con datetime.now(timezone.utc).
    Solleva ValueError se il testo non è una data valida: sta al chiamante
    decidere come trattarla (backup.py ignora l'elemento e lo segnala).
    """
    parsed = datetime.fromisoformat(date_text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed
