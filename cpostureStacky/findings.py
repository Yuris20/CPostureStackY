"""findings.py - Modello comune delle segnalazioni ("finding").

Un finding è un dizionario con sempre le stesse 4 chiavi:

    {
      "category": "Security",          # una tra CATEGORIES
      "severity": "HIGH",              # una tra SEVERITIES
      "resource": "web (ab12cd34)",    # nome e id abbreviato della risorsa
      "message":  "Porta 22 aperta a 0.0.0.0/0",
    }

Questo modulo è l'UNICO punto in cui si definiscono vocabolario (gravità e
categorie) e costruttori dei finding. I check li usano per produrre i risultati,
report.py li usa per presentarli: in questo modo nessuno dei due deve conoscere
i dettagli dell'altro, e un valore non previsto viene intercettato subito.

Errori dei check: se un controllo non riesce a completarsi (API non raggiungibile,
credenziali errate...) NON deve sembrare "tutto a posto". Per questo l'errore è
un finding speciale (resource == CHECK_ERROR_RESOURCE) che il report riconosce e
mostra come "ERRORE" invece di "OK", e che main.py traduce in un exit code diverso.
"""
import logging

logger = logging.getLogger(__name__)

# Dal più grave al meno grave: l'ordine serve anche per ordinare la tabella.
SEVERITIES = ("HIGH", "MEDIUM", "LOW", "INFO")

# Ordine delle categorie nel report.
CATEGORIES = ("Security", "System", "Resource", "Backup")

# Valore del campo "resource" che marca un controllo non completato.
CHECK_ERROR_RESOURCE = "check-error"


def make_finding(category, severity, resource, message):
    """Costruisce un finding validando gravità e categoria.

    La validazione fa fallire subito (ValueError) un check scritto male, invece
    di lasciare che il problema emerga più tardi nella generazione del report.
    """
    if severity not in SEVERITIES:
        raise ValueError(f"Gravità non valida: {severity!r}")
    if category not in CATEGORIES:
        raise ValueError(f"Categoria non valida: {category!r}")
    return {
        "category": category,
        "severity": severity,
        "resource": resource,
        "message": message,
    }


def describe_resource(name, resource_id, unnamed_label="senza-nome"):
    """Testo identificativo di una risorsa: "nome (primi 8 caratteri dell'id)".

    L'id abbreviato permette di distinguere due risorse con lo stesso nome
    (frequente: ogni progetto ha un security group chiamato "default").
    """
    return f"{name or unnamed_label} ({str(resource_id)[:8]})"


def make_error_finding(category, what, exc):
    """Finding che segnala un controllo NON completato a causa di un'eccezione.

    La gravità è INFO (non è un rischio del cloud) ma il campo "resource" lo
    rende riconoscibile: vedi is_check_error().
    I dettagli tecnici (traceback) vanno nel log di livello DEBUG, mentre nel
    report finisce solo tipo e messaggio dell'eccezione.
    """
    logger.warning("%s: %s: %s", what, type(exc).__name__, exc)
    logger.debug("Dettaglio dell'errore", exc_info=exc)
    return make_finding(category, "INFO", CHECK_ERROR_RESOURCE,
                        f"{what}: {type(exc).__name__}: {exc}")


def is_check_error(finding):
    """True se il finding rappresenta un controllo non completato."""
    return finding["resource"] == CHECK_ERROR_RESOURCE


def severity_rank(severity):
    """Posizione della gravità (0 = più grave). Valori ignoti vanno in fondo.

    Il report usa questa funzione invece di SEVERITIES.index() per non andare
    in crash se un finding contiene una gravità imprevista.
    """
    try:
        return SEVERITIES.index(severity)
    except ValueError:
        return len(SEVERITIES)
