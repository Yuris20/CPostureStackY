"""backup.py - Controlli sulla protezione dei dati: snapshot e backup nativi (Cinder).

PERIMETRO (decisione progettuale)
  Si analizzano ESCLUSIVAMENTE i volumi collegati (attachment) ad almeno una VM
  ATTIVA, cioè in stato ACTIVE secondo Nova: sono i dati che un workload sta
  usando adesso. Gli altri volumi sono fuori perimetro:
    - volumi non collegati a nessuna VM ("orfani"): il problema è lo spreco di
      spazio, e lo segnala resource.py. Non ha senso chiedere il backup di un
      volume che nessuno usa, e darebbe due segnalazioni per la stessa causa;
    - volumi collegati solo a VM spente o in errore.
  Il riepilogo INFO finale dichiara quanti volumi sono stati esclusi, così il
  perimetro non è mai nascosto a chi legge il report.
  Il concetto di "VM attiva" è lo stesso di security.py (vedi common.py).

COSA SI INTENDE PER "PROTETTO"
  Un volume è protetto se ha almeno uno snapshot OPPURE un backup nativo, in
  stato "available" e abbastanza recente (non oltre BACKUP_MAX_AGE_DAYS giorni).
    - Snapshot (conn.block_storage.snapshots): copia puntuale che resta sullo
      stesso storage del volume.
    - Backup nativo (conn.block_storage.backups): copia esportata dal servizio
      Cinder Backup verso un back-end esterno (tipicamente Swift/Object Storage).
  Gravità:
    MEDIUM : nessuno snapshot/backup valido, oppure l'ultimo è oltre la soglia
    HIGH   : l'ultimo è più vecchio del DOPPIO della soglia
    LOW    : protezione ancora in creazione, oppure snapshot/backup in errore
  Uno snapshot in stato "creating" non è ancora un backup utilizzabile, ma nemmeno
  un'assenza di protezione: per questo ha un messaggio proprio (non "mancante").

Se il servizio backup non risponde (non installato, Swift assente...) il check
prosegue con i soli snapshot e lo dichiara con un finding INFO: un volume
segnalato come non protetto potrebbe in quel caso avere un backup non verificabile.

READ-ONLY: solo conn.compute.servers(), conn.block_storage.volumes(), snapshots()
e backups() (sole letture).
"""
from datetime import datetime, timezone

from openstack import exceptions as openstack_exceptions

from cpostureStacky import findings as findings_model
from cpostureStacky.checks import common

CATEGORY = "Backup"

VALID_STATUS = "available"    # snapshot/backup completo e utilizzabile
PENDING_STATUS = "creating"   # snapshot/backup ancora in corso di creazione

SNAPSHOT_LABEL = "snapshot"
BACKUP_LABEL = "backup"


def _utc_now():
    """Ora attuale in UTC (funzione separata per poterla sostituire nei test)."""
    return datetime.now(timezone.utc)


def _is_attached_to_active_vm(volume, active_server_ids):
    """True se almeno un attachment del volume punta a una VM attiva.

    'attachments' è la lista (vuota se il volume non è collegato) di dizionari
    Cinder; l'id della VM è nella chiave 'server_id'.
    """
    for attachment in volume.attachments or []:
        if attachment.get("server_id") in active_server_ids:
            return True
    return False


def _index_protections(items, kind_label, undated_labels):
    """Raggruppa snapshot o backup per volume.

    Restituisce tre strutture:
      latest_valid : {id_volume: (data, tipo)} - il più recente con stato 'available'
      pending      : insieme degli id volume con almeno un elemento 'creating'
      failed       : lista di (id_volume, tipo, stato) per gli elementi in errore
    Gli elementi con data illeggibile NON fanno fallire il check: vengono saltati
    e aggiunti (come testo) a undated_labels, così il riepilogo li segnala.
    """
    latest_valid, pending, failed = {}, set(), []
    for item in items:
        status = (item.status or "").lower()
        if status == PENDING_STATUS:
            pending.add(item.volume_id)
        elif "error" in status:
            failed.append((item.volume_id, kind_label, item.status))
        elif status == VALID_STATUS and item.created_at:
            try:
                created_at = common.parse_cinder_date(item.created_at)
            except ValueError:
                undated_labels.append(f"{kind_label} {str(item.id)[:8]}")
                continue
            # Teniamo solo l'elemento più recente per ogni volume
            current = latest_valid.get(item.volume_id)
            if current is None or created_at > current[0]:
                latest_valid[item.volume_id] = (created_at, kind_label)
    return latest_valid, pending, failed


def _list_native_backups(conn):
    """Restituisce (lista backup, disponibile). Se l'API fallisce: ([], False).

    Un errore del servizio backup (SDKException e derivate: servizio assente,
    endpoint non raggiungibile...) non deve far perdere l'analisi degli snapshot.
    """
    try:
        return list(conn.block_storage.backups(details=True, all_projects=True)), True
    except openstack_exceptions.SDKException:
        return [], False


def run(conn, config):
    """Esegue i controlli su snapshot/backup e restituisce la lista di finding."""
    resource_findings = []
    try:
        # 1) Perimetro: VM attive e volumi collegati ad almeno una di esse
        servers_by_id = common.list_servers(conn)
        active_server_ids = {server_id for server_id, server in servers_by_id.items()
                             if common.is_active_server(server)}
        all_volumes = list(conn.block_storage.volumes(details=True, all_projects=True))
        volumes_in_scope = [volume for volume in all_volumes
                            if _is_attached_to_active_vm(volume, active_server_ids)]

        # 2) Snapshot (sempre) e backup nativi (se il servizio risponde)
        snapshots = list(conn.block_storage.snapshots(details=True, all_projects=True))
        native_backups, backups_available = _list_native_backups(conn)

        undated_labels = []
        snap_latest, snap_pending, snap_failed = _index_protections(
            snapshots, SNAPSHOT_LABEL, undated_labels)
        backup_latest, backup_pending, backup_failed = _index_protections(
            native_backups, BACKUP_LABEL, undated_labels)
        pending_volume_ids = snap_pending | backup_pending
        failed_items = snap_failed + backup_failed

        # 3) Valutazione volume per volume
        now = _utc_now()
        max_age_days = config.BACKUP_MAX_AGE_DAYS
        for volume in volumes_in_scope:
            resource_name = findings_model.describe_resource(volume.name, volume.id)

            # La protezione più recente tra snapshot e backup nativo
            candidates = [entry for entry in (snap_latest.get(volume.id),
                                              backup_latest.get(volume.id))
                          if entry is not None]
            if not candidates:
                if volume.id in pending_volume_ids:
                    resource_findings.append(findings_model.make_finding(
                        CATEGORY, "LOW", resource_name,
                        "Snapshot/backup in creazione: nessuno ancora valido"))
                else:
                    note = "" if backups_available else (
                        " (servizio backup non interrogabile: backup nativi non verificati)")
                    resource_findings.append(findings_model.make_finding(
                        CATEGORY, "MEDIUM", resource_name,
                        f"Nessuno snapshot né backup valido presente{note}"))
                continue

            latest_date, latest_kind = max(candidates, key=lambda entry: entry[0])
            # total_seconds/86400: età in giorni con decimali, senza il troncamento
            # che farebbe sembrare "recente" un elemento di 7 giorni e 23 ore.
            age_days = (now - latest_date).total_seconds() / 86400
            if age_days > max_age_days:
                # Oltre il doppio della soglia il problema è più grave
                severity = "HIGH" if age_days > 2 * max_age_days else "MEDIUM"
                resource_findings.append(findings_model.make_finding(
                    CATEGORY, severity, resource_name,
                    f"Ultima protezione ({latest_kind}) vecchia di {age_days:.1f} "
                    f"giorni (soglia {max_age_days})"))

        # 4) Snapshot/backup falliti, ma solo dei volumi nel perimetro
        scope_ids = {volume.id: volume for volume in volumes_in_scope}
        for volume_id, kind_label, status in failed_items:
            if volume_id in scope_ids:
                volume = scope_ids[volume_id]
                resource_findings.append(findings_model.make_finding(
                    CATEGORY, "LOW",
                    findings_model.describe_resource(volume.name, volume.id),
                    f"{kind_label.capitalize()} in stato {status}"))

        # 5) Riepilogo INFO: perimetro e limiti dell'analisi dichiarati nel report
        resource_findings.append(findings_model.make_finding(
            CATEGORY, "INFO", "Volumi analizzati",
            f"{len(volumes_in_scope)} volumi collegati a VM attive analizzati, "
            f"{len(all_volumes) - len(volumes_in_scope)} esclusi "
            f"(non collegati a VM attive)"))
        if not backups_available:
            resource_findings.append(findings_model.make_finding(
                CATEGORY, "INFO", "Backup nativi",
                "Servizio backup Cinder non interrogabile: valutati solo gli snapshot"))
        if undated_labels:
            resource_findings.append(findings_model.make_finding(
                CATEGORY, "INFO", "Date non valide",
                f"{len(undated_labels)} elementi ignorati per data illeggibile: "
                f"{', '.join(undated_labels[:3])}"))
    except Exception as exc:
        resource_findings.append(findings_model.make_error_finding(
            CATEGORY, "Controllo backup non completato", exc))
    return resource_findings
