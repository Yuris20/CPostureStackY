"""security.py - Controlli di sicurezza su Neutron (Security Groups) e Nova (VM).

Un Security Group è il "firewall" delle VM: un insieme di regole che dice quale
traffico può entrare/uscire. Il rischio tipico è una regola che permette
l'accesso da CHIUNQUE su Internet (origine 0.0.0.0/0 per IPv4, ::/0 per IPv6).

Una regola aperta a tutti, però, ha un peso diverso a seconda che il gruppo
protegga davvero un workload oppure no. Per questo il modulo distingue:

  RISCHIO ATTIVO   Il gruppo è associato ad almeno una VM ATTIVA (status ACTIVE).
                   La regola impatta direttamente un workload in esecuzione:
                     HIGH   : tutto il traffico / tutte le porte / porta sensibile
                              (SSH, RDP, database)
                     MEDIUM : un'altra porta TCP/UDP (es. web 80/443)
                     LOW    : ICMP (il "ping")

  IGIENE           Il gruppo NON protegge VM attive: o non è associato ad alcuna
                   VM, oppure lo è solo a VM spente/in errore. È una
                   configurazione residua: viene segnalata sempre come LOW con il
                   prefisso "[Igiene]", qualunque sia la regola, perché oggi non
                   espone nulla. Disattivabile con CPS_REPORT_UNUSED_SG=0 (report
                   solo sui workload).

Come si capisce a quali VM è associato un gruppo (decisione progettuale):
Nova restituisce nei server solo i NOMI dei security group, ambigui tra progetti
(ogni progetto ha un gruppo "default"). Le porte Neutron invece riportano gli ID
dei gruppi. Quindi: si elencano i server (Nova), si elencano le porte (Neutron) e
si associa ogni porta alla sua VM tramite device_id, ricavando "id gruppo -> VM".

Solo regole in INGRESSO (traffico che entra). Non si valuta se la VM sia davvero
raggiungibile da Internet (es. presenza di un floating IP): è un limite noto.

READ-ONLY: usa solo conn.compute.servers(), conn.network.ports() e
conn.network.security_groups() (sole letture).
"""
import ipaddress

from cpostureStacky import findings as findings_model
from cpostureStacky.checks import common

CATEGORY = "Security"

# Neutron può restituire il protocollo come nome o come numero IANA.
# Normalizziamo i numeri più comuni, così "6" e "tcp" sono trattati allo stesso modo.
PROTOCOL_NAMES_BY_NUMBER = {"1": "icmp", "6": "tcp", "17": "udp", "58": "ipv6-icmp"}
ICMP_PROTOCOLS = ("icmp", "ipv6-icmp", "icmpv6")

# Intervallo che copre tutte le porte: equivale a "nessun limite di porta".
FULL_PORT_RANGE = (1, 65535)

# Quanti nomi di VM mostrare nel messaggio (per non produrre righe enormi).
MAX_VM_NAMES_SHOWN = 3

HYGIENE_PREFIX = "[Igiene] "


def _is_open_to_internet(rule):
    """True se la regola ingress accetta traffico da QUALSIASI indirizzo.

    'rule' è un dizionario restituito da Neutron con chiavi come direction,
    protocol, port_range_min, port_range_max, remote_ip_prefix, remote_group_id.
    Si usa .get() perché alcune chiavi possono mancare o valere None.
    """
    if rule.get("direction") != "ingress":
        return False

    remote_prefix = rule.get("remote_ip_prefix")
    if remote_prefix:
        # Si confronta la rete con ipaddress invece del testo: "::/0" e "0::/0"
        # sono la stessa cosa, e una rete con prefisso /0 contiene ogni indirizzo.
        try:
            return ipaddress.ip_network(remote_prefix.strip(), strict=False).prefixlen == 0
        except ValueError:
            return False  # testo non interpretabile come rete: non si può dire "aperta"

    # Nessun prefisso IP: la regola è aperta a tutti solo se non è nemmeno
    # limitata a un altro gruppo (remote_group_id) o a un address group.
    return not rule.get("remote_group_id") and not rule.get("remote_address_group_id")


def _source_label(rule):
    """Testo dell'origine per il messaggio (0.0.0.0/0 oppure ::/0)."""
    remote_prefix = rule.get("remote_ip_prefix")
    if remote_prefix:
        return remote_prefix
    return "::/0" if rule.get("ethertype") == "IPv6" else "0.0.0.0/0"


def evaluate_rule(rule, sensitive_ports):
    """Valuta UNA regola e restituisce (gravità, messaggio), oppure None se è ok.

    La gravità restituita è quella "da rischio attivo": sarà run() a declassarla
    a LOW se il gruppo non protegge VM attive.
    """
    # 1) Regole in uscita o non aperte a tutto Internet: nessuna segnalazione.
    if not _is_open_to_internet(rule):
        return None

    source = _source_label(rule)
    protocol = rule.get("protocol")  # None significa "qualsiasi protocollo"
    first_port = rule.get("port_range_min")
    last_port = rule.get("port_range_max")

    # 2) Nessun protocollo indicato: è permesso TUTTO il traffico.
    if protocol is None:
        return "HIGH", f"Tutto il traffico in ingresso aperto a {source}"
    protocol = PROTOCOL_NAMES_BY_NUMBER.get(str(protocol), str(protocol)).lower()

    # 3) ICMP (ping): rischio basso.
    if protocol in ICMP_PROTOCOLS:
        return "LOW", f"ICMP aperto a {source}"

    # 4) TCP/UDP senza limite di porta, oppure 1-65535: tutte le porte sono aperte.
    if (first_port is None or last_port is None
            or (first_port, last_port) == FULL_PORT_RANGE):
        return "HIGH", f"Tutte le porte {protocol.upper()} aperte a {source}"

    # 5) Testo leggibile per le porte: "22" oppure "8000-9000".
    ports_text = (str(first_port) if first_port == last_port
                  else f"{first_port}-{last_port}")

    # 6) Tra le porte aperte c'è una porta sensibile? (es. l'intervallo 20-30
    #    contiene la 22 e va segnalato anche se la regola non nomina SSH).
    exposed_sensitive_ports = [port for port in sensitive_ports
                               if first_port <= port <= last_port]
    if exposed_sensitive_ports:
        return "HIGH", (f"Porta/e sensibile/i {exposed_sensitive_ports} aperta/e a "
                        f"{source} ({protocol.upper()} {ports_text})")

    # 7) Altre porte aperte a tutti: rischio medio.
    return "MEDIUM", f"Porta {protocol.upper()} {ports_text} aperta a {source}"


def _map_security_groups_to_servers(conn, servers_by_id):
    """Restituisce {id_security_group: [VM che lo usano]}.

    API OpenStack: Neutron, elenco delle porte. Ogni porta di una VM ha come
    device_id l'id del server Nova e come security_group_ids i gruppi applicati.
    Le porte non appartenenti a VM (router, DHCP, load balancer...) non
    corrispondono a nessun server e vengono ignorate.
    """
    servers_by_security_group = {}
    for port in conn.network.ports():
        server = servers_by_id.get(port.device_id)
        if server is None:
            continue
        for security_group_id in port.security_group_ids or []:
            attached_servers = servers_by_security_group.setdefault(security_group_id, [])
            if server not in attached_servers:
                attached_servers.append(server)
    return servers_by_security_group


def _format_vm_names(servers):
    """Elenco leggibile delle VM: 'web, db, app (+2)'."""
    names = sorted(server.name or str(server.id)[:8] for server in servers)
    shown = ", ".join(names[:MAX_VM_NAMES_SHOWN])
    hidden = len(names) - MAX_VM_NAMES_SHOWN
    return f"{shown} (+{hidden})" if hidden > 0 else shown


def run(conn, config):
    """Esegue i controlli di sicurezza e restituisce la lista di finding."""
    resource_findings = []
    try:
        servers_by_id = common.list_servers(conn)
        servers_by_security_group = _map_security_groups_to_servers(conn, servers_by_id)

        groups_in_active_use = 0
        groups_total = 0
        # Per ogni Security Group (di tutti i progetti: siamo admin)...
        for security_group in conn.network.security_groups():
            groups_total += 1
            attached_servers = servers_by_security_group.get(security_group.id, [])
            active_servers = [server for server in attached_servers
                              if common.is_active_server(server)]
            if active_servers:
                groups_in_active_use += 1
            resource_name = findings_model.describe_resource(
                security_group.name, security_group.id)

            # ...controlliamo ogni sua regola
            for rule in security_group.security_group_rules or []:
                assessment = evaluate_rule(rule, config.SENSITIVE_PORTS)
                if assessment is None:
                    continue
                severity, message = assessment

                if active_servers:
                    # RISCHIO ATTIVO: la gravità resta quella della regola.
                    message += f" - usato da VM attive: {_format_vm_names(active_servers)}"
                elif config.REPORT_UNUSED_SECURITY_GROUPS:
                    # IGIENE: configurazione residua, mai più di LOW.
                    reason = ("associato solo a VM non attive" if attached_servers
                              else "non associato ad alcuna VM")
                    severity = "LOW"
                    message = (f"{HYGIENE_PREFIX}{message} - configurazione residua, "
                               f"gruppo {reason}")
                else:
                    continue  # modalità workload-centric: gruppo ignorato

                resource_findings.append(findings_model.make_finding(
                    CATEGORY, severity, resource_name, message))

        # Riepilogo INFO: rende esplicito il perimetro analizzato.
        resource_findings.append(findings_model.make_finding(
            CATEGORY, "INFO", "Security Group totali",
            f"{groups_total} gruppi analizzati, {groups_in_active_use} usati da VM attive"))
    except Exception as exc:
        # Se qualcosa va storto (es. Neutron non risponde) NON blocchiamo il
        # programma, ma l'errore viene reso visibile nel report (non come "OK").
        resource_findings.append(findings_model.make_error_finding(
            CATEGORY, "Controllo Security Groups non completato", exc))
    return resource_findings
