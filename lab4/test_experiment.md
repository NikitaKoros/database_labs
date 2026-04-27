SELECT 
    schemaname,
    tablename,
    attname,
    n_distinct,
    most_common_vals,
    most_common_freqs  -- частоты (селективность каждого значения)
FROM pg_stats 
WHERE tablename = 'rentals' AND attname = 'status';