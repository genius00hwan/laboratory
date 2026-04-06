SELECT user_id, match_score
FROM user_match
WHERE university_id = 1
  AND gender = 'M'
ORDER BY match_score DESC
LIMIT 20;
