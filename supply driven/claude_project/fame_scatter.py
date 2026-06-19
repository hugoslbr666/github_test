import csv, sys, math
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from scipy import stats

log = open('fame_scatter.log', 'w', encoding='utf-8')
sys.stdout = log
sys.stderr = log

rows = []
with open('artist_metrics_and_fame.csv', encoding='utf-8') as f:
    for row in csv.DictReader(f):
        try:
            pull      = float(row['pull_ratio'])
            total_res = int(row['total_results'])
            own_bv    = float(row['bv_artist_own_artworks']) if row['bv_artist_own_artworks'] else 0
            entry_bv  = float(row['entry_bv']) if row['entry_bv'] else 0
            if pull <= 0 or total_res <= 0:
                continue
            rows.append({
                'name': row['artist_name'],
                'pull': pull,
                'results': total_res,
                'log_results': math.log10(total_res),
                'total_bv': own_bv + entry_bv,
                'wiki': row['wikipedia_in_top5'] == 'TRUE',
                'kp':   row['has_knowledge_panel'] == 'TRUE',
            })
        except Exception:
            pass

print(f'Points for scatter: {len(rows)}')

x = np.array([r['log_results'] for r in rows])
y = np.array([r['pull'] for r in rows])

slope, intercept, r_val, p, se = stats.linregress(x, y)
print(f'Pearson r={r_val:.3f}  R2={r_val**2:.3f}  p={p:.2e}  slope={slope:.4f}')

pull_p75 = np.percentile(y, 75)
res_p25  = np.percentile(x, 25)
flags = [r for r in rows if r['pull'] >= pull_p75 and r['log_results'] <= res_p25]
print(f'\nHigh pull + low fame flags: {len(flags)}')
for r in sorted(flags, key=lambda r: r['pull'], reverse=True)[:20]:
    print(f"  {r['name']:<35} pull={r['pull']:.3f}  google={r['results']:,}  wiki={r['wiki']}  kp={r['kp']}  bv=EUR{r['total_bv']:,.0f}")

# --- PLOT ---
fig, ax = plt.subplots(figsize=(12, 7))

for r in rows:
    famous = r['wiki'] or r['kp']
    ax.scatter(r['log_results'], r['pull'],
               c='#d62728' if famous else '#1f77b4',
               alpha=0.8 if famous else 0.25,
               s=18, linewidths=0)

x_line = np.linspace(x.min(), x.max(), 200)
reg_line, = ax.plot(x_line, intercept + slope * x_line, color='black', lw=1.8,
                    label=f'OLS  r={r_val:.2f}  R²={r_val**2:.2f}')

ax.axvline(res_p25,  color='orange', lw=1, ls='--', alpha=0.7)
ax.axhline(pull_p75, color='orange', lw=1, ls='--', alpha=0.7)
ax.fill_betweenx([pull_p75, y.max() * 1.05], x.min(), res_p25, color='orange', alpha=0.07)
ax.text(res_p25 - 0.06, pull_p75 + 0.004, 'Flag zone\n(high pull, low fame)',
        ha='right', fontsize=8, color='darkorange')

for r in sorted(flags, key=lambda r: r['pull'], reverse=True)[:8]:
    ax.annotate(r['name'], xy=(r['log_results'], r['pull']),
                xytext=(5, 3), textcoords='offset points', fontsize=7, color='darkorange')

famous_artists = [r for r in rows if (r['wiki'] or r['kp']) and r['pull'] > np.percentile(y, 82)]
for r in sorted(famous_artists, key=lambda r: r['pull'], reverse=True)[:8]:
    ax.annotate(r['name'], xy=(r['log_results'], r['pull']),
                xytext=(5, 3), textcoords='offset points', fontsize=7, color='#d62728')

ax.set_xlabel('log₁₀(Google search results)   ← less known  |  more known →', fontsize=11)
ax.set_ylabel('Pull ratio  (organic-direct sessions / all touchpoint sessions)', fontsize=11)
ax.set_title('External fame vs. on-site pull ratio\nDoes pull capture real fame, or just SEO luck?',
             fontsize=13, fontweight='bold')

red_patch  = mpatches.Patch(color='#d62728', alpha=0.8, label='Wikipedia or Knowledge Panel')
blue_patch = mpatches.Patch(color='#1f77b4', alpha=0.4, label='No Wikipedia / KP')
ax.legend(handles=[red_patch, blue_patch, reg_line], fontsize=9)
ax.set_xlim(x.min() - 0.2, x.max() + 0.2)
ax.set_ylim(-0.01, min(y.max() * 1.05, 1.0))

plt.tight_layout()
plt.savefig('fame_vs_pull_scatter.png', dpi=150)
print('\nSaved fame_vs_pull_scatter.png')
log.flush()
log.close()
