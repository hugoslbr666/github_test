import pandas as pd
import numpy as np

# Read the CSV
df = pd.read_csv('230626_supply_driven_artist_and_artwork.csv')

print(f"Total artists loaded: {len(df)}")

# Convert numeric columns from string format (with commas) to float
for col in ['artist_total_bv', 'artist_entry_bv_same_artist', 'artist_entry_bv_other_artist',
            'artwork_entry_bv_same_artist', 'artwork_entry_bv_other_artist', '1stClick BV']:
    df[col] = df[col].astype(str).str.replace(',', '').astype(float)

# Convert pull_ratio to numeric (remove %)
df['pull_ratio'] = df['pull_ratio'].str.rstrip('%').astype(float) / 100

# Calculate combined entry BV from both artist and artwork campaigns
df['combined_entry_bv'] = (
    df['artist_entry_bv_same_artist'].fillna(0) +
    df['artist_entry_bv_other_artist'].fillna(0) +
    df['artwork_entry_bv_same_artist'].fillna(0) +
    df['artwork_entry_bv_other_artist'].fillna(0)
)

# Calculate entry_over_total_bv ratio
df['entry_over_total_bv'] = df['combined_entry_bv'] / df['artist_total_bv']

# Clean data: remove rows with missing critical values
df_clean = df[(df['pull_ratio'].notna()) &
              (df['artist_total_bv'].notna()) &
              (df['artist_total_bv'] > 0) &
              (df['pull_ratio'] >= 0)].copy()

print(f"Artists with valid data: {len(df_clean)}")

# Calculate thresholds
pull_threshold = df_clean['pull_ratio'].median()
print(f"\nThresholds:")
print(f"  Pull ratio median: {pull_threshold:.6f} ({pull_threshold*100:.4f}%)")
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
    '1stClick BV': ['sum', 'mean', 'median']
}).round(2)

summary.columns = ['Count', 'Total 1stClick BV (EUR)', 'Mean 1stClick BV (EUR)', 'Median 1stClick BV (EUR)']
summary = summary.sort_values('Total 1stClick BV (EUR)', ascending=False)

print("\n" + "="*80)
print("QUADRANT ANALYSIS SUMMARY (Using 1stClick BV)")
print("="*80)
print(summary.to_string())
print("="*80)

# Export quadrant mapping (artist_id + quadrant)
df_quadrant = df_clean[['artist_id', 'quadrant']].copy()
df_quadrant = df_quadrant.sort_values(['quadrant', 'artist_id'])
df_quadrant.to_csv('artist_quadrant_mapping.csv', index=False)
print(f"\nExported quadrant mapping to: artist_quadrant_mapping.csv ({len(df_quadrant)} artists)")

# Export full details
df_details = df_clean[[
    'artist_id', 'artist_name', 'artist_type', 'quadrant',
    'pull_ratio', 'combined_entry_bv', 'entry_over_total_bv',
    'artist_total_bv', '1stClick BV',
    'nb_sessions_total', 'nb_entry_sessions_total',
    'artist_entry_bv_same_artist', 'artist_entry_bv_other_artist',
    'artwork_entry_bv_same_artist', 'artwork_entry_bv_other_artist'
]].copy()
df_details = df_details.sort_values(['quadrant', 'artist_id'])
df_details.to_csv('artist_quadrant_details.csv', index=False)
print(f"Exported full details to: artist_quadrant_details.csv")

# Print sample from each quadrant
print("\n" + "="*80)
print("SAMPLE ARTISTS PER QUADRANT (Top 5 by 1stClick BV)")
print("="*80)
for quad in summary.index:
    quad_data = df_quadrant[df_quadrant['quadrant'] == quad].merge(
        df_clean[['artist_id', 'artist_name', 'pull_ratio', 'entry_over_total_bv', '1stClick BV']],
        on='artist_id'
    ).nlargest(5, '1stClick BV')

    print(f"\n{quad} ({len(df_quadrant[df_quadrant['quadrant'] == quad])} artists)")
    print(quad_data[['artist_id', 'artist_name', 'pull_ratio', 'entry_over_total_bv', '1stClick BV']].to_string(index=False))

print("\n" + "="*80)
