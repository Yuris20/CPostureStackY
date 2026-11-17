"""config.py - Configurazione centrale del progetto.

Qui sono raccolti TUTTI i valori modificabili (soglie, nomi, percorsi).
Così per cambiare il comportamento del programma non serve toccare i check.

Ogni valore può essere cambiato senza modificare il codice impostando una
variabile d'ambiente, ad esempio:
    CPS_BACKUP_MAX_AGE_DAYS=3 python -m cpostureStacky.main
Se la variabile non esiste, viene usato il valore di default (secondo argomento
di os.environ.get). Questo file è l'UNICA fonte dei valori di default: lo script
devstack/plugin.sh si limita a inoltrare le variabili CPS_* eventualmente definite.
"""
import os

# Radice del repository: parte dal percorso di questo file (config.py),
# sale di una cartella (da cpostureStacky/ alla radice del progetto).
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Nome del "cloud" definito nel file clouds.yaml.
# DevStack crea automaticamente un cloud chiamato 'devstack-admin' con le
# credenziali di amministratore: è lì che openstacksdk le va a leggere.
CLOUD_NAME = os.environ.get("CPS_CLOUD", "devstack-admin")

# Cartella dove viene salvato il report HTML (default: <repo>/reports).
REPORTS_DIR = os.environ.get("CPS_REPORTS_DIR", os.path.join(BASE_DIR, "reports"))


def _env_flag(name, default):
    """Legge una variabile d'ambiente booleana: '1', 'true', 'yes', 'on' = vero."""
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


# ---------------------------- SOGLIE E OPZIONI ----------------------------

# Security: se una di queste porte è aperta a tutto Internet (0.0.0.0/0 o ::/0)
# la segnalazione è di gravità HIGH. 22=SSH, 3389=Desktop remoto (RDP),
# 3306=MySQL, 5432=PostgreSQL.
SENSITIVE_PORTS = [22, 3389, 3306, 5432]

# Security: segnalare anche i security group NON usati da VM attive, come
# controllo di "igiene" (sempre gravità LOW, mai di più)? Se vale False il
# report è puramente "workload-centric": solo i gruppi che proteggono VM attive.
REPORT_UNUSED_SECURITY_GROUPS = _env_flag("CPS_REPORT_UNUSED_SG", True)

# Resource: percentuale di utilizzo di RAM/vCPU oltre la quale si segnala.
# Sopra la soglia "WARN" -> MEDIUM; sopra la soglia "CRIT" -> HIGH.
# int(...) serve perché le variabili d'ambiente sono sempre stringhe.
RAM_USAGE_WARN_PERCENT = int(os.environ.get("CPS_RAM_WARN", "80"))
VCPU_USAGE_WARN_PERCENT = int(os.environ.get("CPS_VCPU_WARN", "80"))
USAGE_CRIT_PERCENT = int(os.environ.get("CPS_USAGE_CRIT", "95"))

# Backup: età massima (in giorni) dell'ultima protezione di un volume, cioè del
# più recente tra snapshot e backup nativo validi. Oltre questa soglia la
# protezione è considerata "vecchia". Il nome precedente della variabile
# (CPS_SNAPSHOT_MAX_AGE_DAYS) resta accettato per compatibilità.
BACKUP_MAX_AGE_DAYS = int(os.environ.get(
    "CPS_BACKUP_MAX_AGE_DAYS",
    os.environ.get("CPS_SNAPSHOT_MAX_AGE_DAYS", "7")))
