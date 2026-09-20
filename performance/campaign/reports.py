"""CSV e informe comparativo. El HTML de cada corrida lo genera k6."""

import csv
import json
import statistics

from .configuration import results_path

CSV_FIELDS = [
    "scenario",
    "profile",
    "nodes",
    "offered_ops_s",
    "reference_R",
    "repetition",
    "samples",
    "p50",
    "p95",
    "p95_limit_ms",
    "p99",
    "error_rate",
    "http_error_rate",
    "network_errors",
    "dropped",
    "completed_ops_s",
    "requests_s",
    "valid",
    "recovery",
]


def compare_topologies(results):
    lines = []
    for scenario in ("api", "web"):
        for rate in (1, 2, 5, 10, 20, 40):
            by_nodes = {1: [], 2: []}
            for result in results:
                matches_reference = (
                    result["scenario"] == scenario
                    and result["profile"] == "sustained"
                    and result["reference_R"] == rate
                    and result["valid"]
                )
                if matches_reference and result["nodes"] in by_nodes:
                    by_nodes[result["nodes"]].append(result["p95"])

            primary, replica = by_nodes[1], by_nodes[2]
            if len(primary) < 2 or len(replica) < 2:
                continue

            primary_mean = statistics.mean(primary)
            replica_mean = statistics.mean(replica)
            improvement = 100 * (primary_mean - replica_mean) / primary_mean
            lines.append(
                f"- {scenario}, R={rate}: mejora p95 {improvement:.1f}%; "
                f"rangos {min(primary):.1f}–{max(primary):.1f} / "
                f"{min(replica):.1f}–{max(replica):.1f} ms."
            )
    return lines


def aggregate(root):
    root = results_path(root)
    results = [json.loads(path.read_text()) for path in sorted(root.glob("**/summary.json"))]
    with (root / "table.csv").open("w") as stream:
        writer = csv.DictWriter(stream, CSV_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(results)

    lines = [
        "# LoResuelvo — campaña de lecturas",
        "",
        "Resultados privados. No extrapolar a producción, tres nodos ni escrituras.",
        "",
        "| Escenario | Perfil | Nodos | R | p95 ms | Válida | Recuperación |",
        "|---|---|---|---|---|---|---|",
    ]
    for result in results:
        lines.append(
            f"| {result['scenario']} | {result['profile']} | {result['nodes']} "
            f"| {result['reference_R']} | {result['p95']} | {result['valid']} "
            f"| {result['recovery']} |"
        )
    lines += ["", "## Comparación de repeticiones sostenidas", ""]
    lines += compare_topologies(results)
    lines += [
        "",
        "## Evidencia operativa",
        "",
        "Dataset y checksum, versiones/digests, recursos compartidos, PostgreSQL, distribución por nodo,",
        "caché/Cloudflare, saturación del generador, bloqueos y limpieza final: ver `status.md`.",
        "Si faltara esa evidencia la comparación sería inconclusa. Si no hubo degradación: capacidad probada",
        "de al menos X; nunca declarar máximo. Las curvas están en report.html por ejecución.",
    ]
    (root / "report.md").write_text("\n".join(lines) + "\n")
