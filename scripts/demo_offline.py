"""demo_offline.py - Dimostrazione di CPostureStackY SENZA OpenStack.

Esegue i quattro moduli di controllo REALI e il VERO generatore di report, ma su un
cloud SIMULATO che riproduce lo scenario di demo_setup.sh (modalità completa):
nessuna VM, nessun volume e nessun servizio vengono creati, quindi non carica la
macchina e non richiede DevStack.

ATTENZIONE: è una simulazione. Dimostra la logica dei controlli e il report, NON
sostituisce una prova su un OpenStack reale (le risposte delle API sono imitate dagli
oggetti finti di tests/fakes.py).

Uso (dalla cartella principale del progetto):
    python scripts/demo_offline.py
Il report viene salvato in reports/ con la dicitura "SIMULATO" nell'intestazione.
"""
import os
import sys
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

# Rende importabili il package cpostureStacky e la cartella tests/ anche quando lo
# script è lanciato come "python scripts/demo_offline.py".
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO_ROOT)

from cpostureStacky import config, report  # noqa: E402
from cpostureStacky.checks import backup, resource, security, system  # noqa: E402
from tests import fakes  # noqa: E402


def build_simulated_cloud():
    """Cloud finto con lo stesso scenario di demo_setup.sh (modalità completa)."""
    now = datetime.now(timezone.utc)

    def days_ago(days):
        return (now - timedelta(days=days)).replace(tzinfo=None).isoformat()

    vm_active = "aaaa1111-0000-0000-0000-000000000001"
    vm_stopped = "bbbb2222-0000-0000-0000-000000000002"
    servers = [
        fakes.server(vm_active, "cps-demo-vm-active", "ACTIVE"),
        fakes.server(vm_stopped, "cps-demo-vm-stopped", "SHUTOFF", power_state=4),
    ]
    ports = [
        fakes.port(vm_active, ["sg-web", "sg-internal"]),
        fakes.port(vm_stopped, ["sg-stopped"]),
    ]
    security_groups = [
        fakes.security_group("sg-web", "cps-demo-sg-web",
                             [fakes.tcp_rule(22), fakes.tcp_rule(80), fakes.tcp_rule(3306)]),
        fakes.security_group("sg-internal", "cps-demo-sg-internal",
                             [fakes.tcp_rule(22, remote_ip_prefix="10.0.0.0/8")]),
        fakes.security_group("sg-stopped", "cps-demo-sg-stopped", [fakes.tcp_rule(22)]),
        fakes.security_group("sg-orphan", "cps-demo-sg-orphan", [fakes.tcp_rule(3306)]),
    ]

    def demo_volume(short_name, attached_to=()):
        return fakes.volume(f"{short_name}-0000", f"cps-demo-{short_name}", attached_to)

    volumes = [
        demo_volume("vol-protected", [vm_active]),
        demo_volume("vol-backup", [vm_active]),
        demo_volume("vol-nobackup", [vm_active]),
        demo_volume("vol-orphan"),
        demo_volume("vol-onstopped", [vm_stopped]),
    ]
    snapshots = [fakes.snapshot_or_backup("snap-1", "vol-protected-0000", days_ago(0.1))]
    native_backups = [fakes.snapshot_or_backup("backup-1", "vol-backup-0000", days_ago(0.1))]

    # Nessun dato hypervisor (come con Nova recenti): si usano le quote del progetto
    hypervisors = [SimpleNamespace(name="devstack", memory_size=None, vcpus=None)]
    limits = SimpleNamespace(absolute=SimpleNamespace(
        total_ram=51200, total_ram_used=4096, total_cores=20, total_cores_used=2))
    return fakes.FakeConnection(
        servers=servers, ports=ports, security_groups=security_groups, volumes=volumes,
        snapshots=snapshots, backups=native_backups, hypervisors=hypervisors, limits=limits)


def main():
    print("*** DEMO OFFLINE: dati SIMULATI, nessuna chiamata a OpenStack ***\n")
    connection = build_simulated_cloud()
    all_findings = []
    for check_module in (security, system, resource, backup):
        all_findings += check_module.run(connection, config)
    report_path = report.generate_html(
        all_findings, config.REPORTS_DIR, "SIMULATO (nessun OpenStack)")
    report.print_console(all_findings)
    print(f"\nReport HTML: {report_path}")


if __name__ == "__main__":
    main()
