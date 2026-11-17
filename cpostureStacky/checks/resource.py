"""resource.py - Controlli sulle risorse (Nova + Cinder).

Due controlli:
  1) CAPACITÀ: quanta RAM e quante vCPU sono in uso rispetto al totale.
     Prima si guardano gli "hypervisor" (i server fisici che ospitano le VM).
     Dalla microversion 2.88 di Nova (e quindi sui cloud recenti) questi dati
     non sono più esposti dall'API degli hypervisor: in quel caso si ripiega
     sulle QUOTE del progetto dell'utente e il report lo dichiara con un INFO.
     Le quote misurano un limite amministrativo di UN progetto, non la capacità
     fisica del cloud: sono un ripiego, non un equivalente.
  2) VOLUMI ORFANI: un volume Cinder "available" e senza collegamento a
     nessuna VM occupa spazio senza essere usato (spreco). È QUI, e solo qui,
     che si gestisce l'orfano: backup.py non lo segnala come "senza backup".
     Si segnalano anche i volumi in stato di errore.

READ-ONLY: solo chiamate di lettura (hypervisors, get_limits, volumes).
"""
from cpostureStacky.findings import describe_resource, make_error_finding, make_finding

CATEGORY = "Resource"


def _usage_finding(label, resource_name, used, total, warn_percent, crit_percent):
    """Confronta 'usato' e 'totale' con le soglie.

    label         : cosa stiamo misurando ("RAM", "vCPU")
    resource_name : nome della risorsa misurata (es. l'hypervisor)
    used, total   : valori usati e totali
    warn_percent, crit_percent : soglie in percentuale
    Restituisce un finding oppure None se l'utilizzo è sotto la soglia.
    """
    if not total:           # totale 0 o mancante: evitiamo la divisione per zero
        return None
    usage_percent = used * 100.0 / total
    if usage_percent >= crit_percent:
        severity = "HIGH"
    elif usage_percent >= warn_percent:
        severity = "MEDIUM"
    else:
        return None         # utilizzo normale: nessuna segnalazione
    return make_finding(CATEGORY, severity, resource_name,
                        f"{label} al {usage_percent:.0f}% ({used}/{total})")


def _check_hypervisors(conn, config):
    """Controlla RAM e vCPU di ogni hypervisor.

    Ritorna una tripla: (lista di finding, numero di hypervisor, dati_disponibili).
    'dati_disponibili' vale False se Nova non ha restituito i campi: in tal
    caso run() ripiegherà sulle quote del progetto. Il numero di hypervisor
    permette di distinguere "elenco vuoto" da "elenco presente ma senza i campi".
    """
    usage_findings, hypervisor_count, data_available = [], 0, False
    for hypervisor in conn.compute.hypervisors(details=True):
        hypervisor_count += 1
        # Con le microversion di Nova >= 2.88 questi campi non esistono:
        # getattr(..., None) restituisce None invece di dare errore.
        ram_total = getattr(hypervisor, "memory_size", None)
        vcpu_total = getattr(hypervisor, "vcpus", None)
        if ram_total is None and vcpu_total is None:
            continue
        data_available = True
        for usage_finding in (
            _usage_finding("RAM", hypervisor.name,
                           getattr(hypervisor, "memory_used", 0) or 0, ram_total,
                           config.RAM_USAGE_WARN_PERCENT, config.USAGE_CRIT_PERCENT),
            _usage_finding("vCPU", hypervisor.name,
                           getattr(hypervisor, "vcpus_used", 0) or 0, vcpu_total,
                           config.VCPU_USAGE_WARN_PERCENT, config.USAGE_CRIT_PERCENT),
        ):
            if usage_finding:
                usage_findings.append(usage_finding)
    return usage_findings, hypervisor_count, data_available


def _check_project_quota(conn, config):
    """Piano B: utilizzo di RAM/vCPU rispetto alle QUOTE del progetto.

    Le quote sono i limiti massimi di risorse assegnati a un progetto: qui si
    legge quello dell'utente con cui ci si è autenticati.
    """
    absolute_limits = conn.compute.get_limits().absolute  # limiti e consumi
    quota_findings = []
    for usage_finding in (
        _usage_finding("RAM (quota progetto)", "quota progetto",
                       getattr(absolute_limits, "total_ram_used", 0) or 0,
                       getattr(absolute_limits, "total_ram", None),
                       config.RAM_USAGE_WARN_PERCENT, config.USAGE_CRIT_PERCENT),
        _usage_finding("vCPU (quota progetto)", "quota progetto",
                       getattr(absolute_limits, "total_cores_used", 0) or 0,
                       getattr(absolute_limits, "total_cores", None),
                       config.VCPU_USAGE_WARN_PERCENT, config.USAGE_CRIT_PERCENT),
    ):
        if usage_finding:
            quota_findings.append(usage_finding)
    return quota_findings


def _check_volumes(conn):
    """Cerca volumi orfani (available e senza attachment) o in errore."""
    volume_findings = []
    for volume in conn.block_storage.volumes(details=True, all_projects=True):
        resource_name = describe_resource(volume.name, volume.id)
        status = (volume.status or "").lower()
        # 'attachments' è la lista dei collegamenti a VM: vuota = non usato
        if status == "available" and not volume.attachments:
            volume_findings.append(make_finding(
                CATEGORY, "MEDIUM", resource_name,
                f"Volume orfano: {volume.size} GB non collegato a nessuna VM"))
        elif "error" in status:
            volume_findings.append(make_finding(
                CATEGORY, "MEDIUM", resource_name, f"Volume in stato {status}"))
    return volume_findings


def run(conn, config):
    """Esegue tutti i controlli sulle risorse e restituisce la lista di finding.

    I due controlli sono in try/except SEPARATI: se uno fallisce, l'altro
    viene eseguito comunque.
    """
    resource_findings = []

    try:
        hypervisor_findings, hypervisor_count, data_available = _check_hypervisors(
            conn, config)
        if data_available:
            resource_findings += hypervisor_findings
        else:
            # Ripiego dichiarato: chi legge il report deve sapere che la
            # misura NON riguarda la capacità fisica del cloud, e perché.
            if hypervisor_count == 0:
                reason = ("Nova non ha restituito alcun hypervisor (elenco vuoto o "
                          "permessi insufficienti)")
            else:
                reason = ("Dati di utilizzo degli hypervisor non disponibili (campi "
                          "assenti: tipico di Nova con microversion >= 2.88)")
            resource_findings.append(make_finding(
                CATEGORY, "INFO", "Capacità hypervisor",
                f"{reason}: uso le quote del progetto"))
            resource_findings += _check_project_quota(conn, config)
    except Exception as exc:
        resource_findings.append(make_error_finding(
            CATEGORY, "Capacità non verificata", exc))

    try:
        resource_findings += _check_volumes(conn)
    except Exception as exc:
        resource_findings.append(make_error_finding(
            CATEGORY, "Volumi non verificati", exc))

    return resource_findings
