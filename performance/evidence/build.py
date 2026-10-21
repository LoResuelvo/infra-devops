#!/usr/bin/env python3
"""Consolidar resúmenes remotos sin exportar cookies, logs ni configuración privada."""
import csv
import hashlib
import json
from pathlib import Path
import os
os.environ.setdefault('MPLCONFIGDIR', '/tmp/loresuelvo-matplotlib')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'results/consolidated'
CAMPAIGNS = ['staging-campaign', 'staging-api-v0.0.71', 'staging-api-v0.0.71-final',
             'availability-20260919', 'availability-20260920',
             'availability-20260920-retry', 'mvp-20261020', 'availability-20261021']
FIELDS = ['campaign','run','timestamp','scenario','profile','purpose','nodes','seconds',
          'reference_R','samples','requests','p50','p95','p99','error_rate','network_errors',
          'dropped','exit_code','valid','measurement_valid','slo_met','p95_limit_ms',
          'source_revision','scenario_sha256','dataset_selection_sha256','summary_sha256','classification']


def collect():
    rows = []
    for campaign in CAMPAIGNS:
        for p in sorted((ROOT / 'results' / campaign).glob('**/summary.json')):
            x = json.loads(p.read_text())
            row = {k: x.get(k) for k in FIELDS}
            row.update(campaign=campaign, run=str(p.parent.relative_to(ROOT)),
                       summary_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
            if x.get('purpose') == 'warmup' or x['profile'] in ('smoke','warmup'):
                kind = 'control_previo'
            elif campaign == 'mvp-20261020' and 'sustained-r1/run-3' in str(p):
                kind = 'incidente_dns_excluido_capacidad'
            elif campaign == 'mvp-20261020' and x['profile'] == 'availability':
                kind = 'retiro_inconcluso_transporte'
            elif campaign == 'availability-20260919' and x['profile'] == 'availability':
                kind = 'referencia_sin_retiro'
            elif x['profile'] == 'availability':
                kind = 'retiro_evaluar_por_fases'
            else:
                kind = 'resultado_carga'
            row['classification'] = kind
            rows.append(row)
    return rows


def save(fig, name):
    fig.savefig(OUT / f'{name}.pdf', bbox_inches='tight')
    fig.savefig(OUT / f'{name}.png', dpi=220, bbox_inches='tight')
    plt.close(fig)


def curves(rows, campaign, name, title):
    selected = [r for r in rows if r['campaign']==campaign and r['profile']=='explore' and r['nodes']==1]
    scenarios = sorted(set(r['scenario'] for r in selected))
    fig, axes = plt.subplots(len(scenarios), 2, figsize=(10, 3.5*len(scenarios)), squeeze=False, layout='constrained')
    for i, scenario in enumerate(scenarios):
        ss=sorted([r for r in selected if r['scenario']==scenario], key=lambda r:(r['reference_R'],r['timestamp']))
        repeated=len({r['reference_R'] for r in ss}) < len(ss)
        for ax,(key,label,target) in zip(axes[i],[('p95','p95 de operación (ms)',1500),('error_rate','Operaciones fallidas (%)',1)]):
            mult=100 if key=='error_rate' else 1
            values=[r[key]*mult for r in ss]
            ax.plot([r['reference_R'] for r in ss],values,'o' if repeated else '-o',color='#226b89',lw=1.6,ms=5,label='Valor observado')
            ax.set_xscale('log',base=2);ax.set_xticks(sorted({r['reference_R'] for r in ss}))
            ax.xaxis.set_major_formatter(matplotlib.ticker.StrMethodFormatter('{x:g}'))
            ax.set(xlabel='Tasa ofrecida (operaciones/s)',ylabel=label,title=scenario.upper())
            ax.axhline(target,color='#b56539',ls='--',lw=1.2,label=f'Referencia: {target:g}'+(' ms' if key=='p95' else ' %'))
            all_values=[r[key]*mult for r in selected]
            ax.set_ylim(0,max([target,*all_values])*1.25)
            ax.margins(x=.12);ax.grid(axis='y',alpha=.2);ax.legend(loc='upper left',fontsize=8,frameon=False)
    fig.suptitle(title,fontsize=12)
    save(fig,name)


def topology(rows):
    ss=[r for r in rows if r['campaign']=='mvp-20261020' and r['profile']=='sustained' and r['reference_R']==2]
    fig,axes=plt.subplots(1,2,figsize=(10,3.6),layout='constrained')
    for nodes,color in [(1,'#226b89'),(2,'#78619b')]:
        runs=sorted([r for r in ss if r['nodes']==nodes],key=lambda r:r['timestamp'])
        for ax,key,mult in [(axes[0],'p95',1),(axes[1],'error_rate',100)]:
            for i,r in enumerate(runs):
                x=nodes+(i-1)*.12
                ax.scatter(x,r[key]*mult,color=color,s=35,zorder=3)
                label=f"R{i+1}: {r['p95']:.0f}" if key=='p95' else f"R{i+1}: {round(r['samples']*r['error_rate'])}/{r['samples']}"
                ax.annotate(label,(x,r[key]*mult),xytext=(0,8 if key=='p95' else 8+12*(i%2)),textcoords='offset points',ha='center',fontsize=7)
            ax.set_xticks([1,2],['Un nodo','Dos nodos']);ax.set_xlim(.55,2.45);ax.grid(axis='y',alpha=.2)
    axes[0].set(ylabel='p95 de operación (ms)',ylim=(0,1800));axes[0].axhline(1500,color='#b56539',ls='--',lw=1)
    axes[1].set(ylabel='Operaciones fallidas (%)',ylim=(-.06,1.25));axes[1].axhline(1,color='#b56539',ls='--',lw=1)
    fig.suptitle('Octubre · 2 búsquedas/s · tres ventanas de cinco minutos por topología')
    save(fig,'topologias-octubre')


def historical_tables(rows):
    target=OUT/'documentation';target.mkdir(exist_ok=True)
    slash=chr(92)
    def fmt(value):
        return str(value).replace('.',',') if value is not None else '--'
    with (target/'tablas_historicas.tex').open('w') as f:
        for campaign in CAMPAIGNS[:3]:
            selected=sorted([r for r in rows if r['campaign']==campaign and r['profile'] in ('explore','sustained','spike')],key=lambda r:(r['scenario'],r['profile'],r['nodes'],r['reference_R'],r['timestamp']))
            lines=[slash+'begin{table}[htbp]',slash+'centering'+slash+'scriptsize',slash+'begin{tabular}{lllrrrrr}',slash+'toprule', 'Escenario & Perfil & Nodos/tasa & n & p95 ms & Fallos '+slash+'% & Descartes & s '+slash*2,slash+'midrule']
            for r in selected:
                fields=[r['scenario'].upper(),{'explore':'Exploración','sustained':'Sostenida','spike':'Pico'}[r['profile']],f"{r['nodes']} / {fmt(r['reference_R'])}",str(r['samples']),str(r['p95']),fmt(round(100*r['error_rate'],2)),str(r['dropped']),str(r['seconds'])]
                lines.append(' & '.join(fields)+' '+slash*2)
            lines += [slash+'bottomrule',slash+'end{tabular}',slash+'caption{'+{'staging-campaign':'Septiembre: campaña inicial de API y web','staging-api-v0.0.71':'Septiembre: campaña intermedia de API v0.0.71','staging-api-v0.0.71-final':'Septiembre: campaña completa de API y web posterior a la optimización de lectura'}[campaign]+'. Referencia R en operaciones/s (en pico, la tasa varía); duración planificada en segundos. Cada fila conserva una ejecución.}',slash+'end{table}','']
            f.write(chr(10).join(lines)+chr(10))


def availability_plot(run, events, name, title, limit_ms):
    from datetime import datetime
    def ts(value):
        return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
    rows=[]
    for line in (ROOT/run/'points.jsonl').open():
        point=json.loads(line)
        if point.get('type')=='Point' and point.get('metric')=='operation_ms':
            d=point['data'];rows.append((float(d['tags']['started_ms'])/1000,ts(d['time']),d['value'],d['tags']['failed']=='true'))
    start=min(r[0] for r in rows);end=start+1200
    event=json.loads((ROOT/events).read_text())
    drain=ts(event['down_requested']);verified=ts(event['down_verified'])
    fig,axes=plt.subplots(2,1,figsize=(10,5.3),sharex=True,layout='constrained')
    for ax in axes:
        for a,b,color in [(start,drain,'#dce8ed'),(drain,verified,'#f4e4d2'),(verified,end,'#e3eade')]:
            ax.axvspan((a-start)/60,(b-start)/60,color=color,alpha=.6,zorder=0)
        for event_time in (drain,verified):ax.axvline((event_time-start)/60,color='#686868',ls=':',lw=1)
        ax.grid(axis='y',alpha=.2);ax.set_xlim(0,20)
    ok=[r for r in rows if not r[3]];bad=[r for r in rows if r[3]]
    axes[0].scatter([(r[0]-start)/60 for r in ok],[r[2] for r in ok],s=8,alpha=.45,color='#226b89',label='Operación correcta')
    if bad:axes[0].scatter([(r[0]-start)/60 for r in bad],[r[2] for r in bad],marker='x',s=35,color='#a74434',label='Operación fallida',zorder=4)
    axes[0].axhline(limit_ms,color='#b56539',ls='--',lw=1,label=f'Referencia de p95: {limit_ms} ms')
    axes[0].set(ylabel='Duración de operación (ms)',ylim=(0,max(limit_ms,max(r[2] for r in rows))*1.2));axes[0].legend(fontsize=8,frameon=False)
    successes=sorted(r[1] for r in ok)
    axes[1].plot([(t-start)/60 for t in successes[1:]],[b-a for a,b in zip(successes,successes[1:])],color='#226b89',lw=.9)
    axes[1].axhline(10,color='#b56539',ls='--',lw=1,label='Referencia: 10 s')
    axes[1].set(ylabel='Intervalo entre éxitos (s)',xlabel='Tiempo desde el inicio (minutos)',ylim=(0,max(12,max(b-a for a,b in zip(successes,successes[1:]))*1.2)))
    axes[1].set_xticks(range(0,21,2));axes[1].legend(fontsize=8,frameon=False)
    axes[0].text((drain-start)/60,.99,' Solicitud de baja',transform=axes[0].get_xaxis_transform(),va='top',fontsize=8)
    axes[0].text((verified-start)/60,.89,' Retiro verificado',transform=axes[0].get_xaxis_transform(),va='top',fontsize=8)
    fig.suptitle(title,fontsize=12);save(fig,name)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':9,'axes.spines.top':False,'axes.spines.right':False,'pdf.fonttype':42})
    rows=collect()
    with (OUT/'runs.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=FIELDS);writer.writeheader();writer.writerows(rows)
    (OUT/'runs.json').write_text(json.dumps(rows,indent=2,ensure_ascii=False)+'\n')
    with (OUT/'inventory.md').open('w') as f:
        f.write('# Inventario de campañas remotas\n\n')
        for campaign in CAMPAIGNS:
            selected=[r for r in rows if r['campaign']==campaign]
            f.write(f'## {campaign}\n\n')
            f.write('| Ejecución | Escenario/perfil | Nodos | Tasa op/s | n | p95 ms | Fallos % | Clasificación |\n|---|---|---:|---:|---:|---:|---:|---|\n')
            for r in selected:
                run=r['run'].split(campaign+'/',1)[-1]
                f.write(f"| {run} | {r['scenario']}/{r['profile']} | {r['nodes']} | {r['reference_R']} | {r['samples']} | {r['p95']} | {100*r['error_rate']:.2f} | {r['classification']} |\n")
            f.write('\n')
    curves(rows,'staging-api-v0.0.71-final','exploracion-septiembre','Septiembre · API y web son operaciones diferentes')
    curves(rows,'mvp-20261020','exploracion-octubre','Octubre · búsqueda web autenticada · un nodo')
    topology(rows)
    historical_tables(rows)
    availability_plot(Path('results/availability-20260920-retry/moderate/run-1'),Path('results/availability-20260920-retry/moderate/events.json'),'retiro-septiembre','Septiembre · continuidad observada durante retiro planificado',2000)
    print(f'{len(rows)} ejecuciones inventariadas; artefactos en {OUT}')

if __name__=='__main__':
    main()
