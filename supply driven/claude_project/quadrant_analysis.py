import csv
import pandas as pd

# Read the CSV
df = pd.read_csv('artist_metrics_and_fame.csv')

# Clean data: remove rows with missing critical values
df_clean = df[(df['pull_ratio'].notna()) &
              (df['total bv'].notna()) &
              (df['total bv'] > 0) &
              (df['pull_ratio'] > 0)].copy()

print(f"Total artists with valid data: {len(df_clean)}")

# Calculate thresholds
pull_threshold = df_clean['pull_ratio'].median()
bv_threshold = df_clean['total bv'].median()

print(f"\nThresholds:")
print(f"  Pull ratio median: {pull_threshold:.4f}")
print(f"  Total BV median: EUR {bv_threshold:,.2f}")
print(f"  Entry over total BV threshold: > 0 (explicitly separate zero vs non-zero)")

# Define quadrants based on pull_ratio and entry_over_total_bv > 0
def assign_quadrant(row):
    high_pull = row['pull_ratio'] >= pull_threshold
    high_entry_bv = row['entry_over_total_bv'] > 0

    if high_pull and high_entry_bv:
        return 'Supply-Driven (High Pull, High Entry BV)'
    elif high_pull and not high_entry_bv:
        return 'Pull but no BV (High Pull, Low/Zero Entry BV)'
    elif not high_pull and high_entry_bv:
        return 'BV but no pull (Low Pull, High Entry BV)'
    else:
        return 'Demand-driven (Low Pull, Low/Zero Entry BV)'

df_clean['quadrant'] = df_clean.apply(assign_quadrant, axis=1)

# Summary statistics
summary = df_clean.groupby('quadrant').agg({
    'artist_id': 'count',
    'total bv': ['sum', 'mean', 'median']
}).round(2)

summary.columns = ['Count', 'Total BV (EUR)', 'Mean BV (EUR)', 'Median BV (EUR)']
summary = summary.sort_values('Total BV (EUR)', ascending=False)

print("\n" + "="*80)
print("QUADRANT ANALYSIS SUMMARY")
print("="*80)
print(summary.to_string())
print("="*80)

# Export detailed quadrant mapping
df_quadrant = df_clean[['artist_id', 'artist_name', 'pull_ratio', 'entry_over_total_bv', 'total bv', 'quadrant']].copy()
df_quadrant = df_quadrant.sort_values(['quadrant', 'artist_id'])

df_quadrant[['artist_id', 'quadrant']].to_csv('artist_quadrant_mapping.csv', index=False)
print(f"\nExported detailed mapping to: artist_quadrant_mapping.csv ({len(df_quadrant)} artists)")

# Also export full details
df_quadrant.to_csv('artist_quadrant_details.csv', index=False)
print(f"Exported full details to: artist_quadrant_details.csv")

# Print sample from each quadrant
print("\n" + "="*80)
print("SAMPLE ARTISTS PER QUADRANT (Top 5 by Total BV)")
print("="*80)
for quad in summary.index:
    quad_data = df_quadrant[df_quadrant['quadrant'] == quad].nlargest(5, 'total bv')
    print(f"\n{quad} ({len(df_quadrant[df_quadrant['quadrant'] == quad])} artists)")
    print(quad_data[['artist_id', 'artist_name', 'pull_ratio', 'entry_over_total_bv', 'total bv']].to_string(index=False))
