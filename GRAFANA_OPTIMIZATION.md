# Guide d'Optimisation des Dashboards Grafana

Ce document explique comment migrer vos dashboards Grafana pour utiliser les tables agrégées optimisées.

## 🎯 Stratégie Générale

### Règle de Sélection des Tables

| Période de temps | Table à utiliser | Raison |
|------------------|------------------|--------|
| < 2 jours | `linky_realtime` | Données en temps réel (1/sec) |
| 2 jours - 90 jours | `linky_daily` | Vue quotidienne rapide |
| > 90 jours | `linky_monthly` | Vue mensuelle très rapide |

### Variable Grafana pour Table Dynamique

Ajoutez cette variable dans votre dashboard pour sélectionner automatiquement la bonne table :

```sql
-- Variable: selected_table
-- Type: Query
SELECT 
    CASE 
        WHEN TIMESTAMPDIFF(HOUR, $__timeFrom(), $__timeTo()) <= 48 THEN 'linky_realtime'
        WHEN TIMESTAMPDIFF(DAY, $__timeFrom(), $__timeTo()) <= 90 THEN 'linky_daily'
        ELSE 'linky_monthly'
    END as table_name
```

---

## 📊 Exemples de Conversion

### 1. Graphique de Puissance Apparente (Temps Réel)

**❌ Avant (non optimisé)** :
```sql
SELECT 
    $__timeGroupAlias(time, $__interval), 
    ROUND(PAPP * $cosphi / 5) * 5 AS "Puissance apparente" 
FROM linky.linky_realtime 
WHERE $__timeFilter(time)
```

**✅ Après (optimisé - INCHANGÉ)** :
```sql
-- Aucun changement nécessaire pour les données temps réel
SELECT 
    $__timeGroupAlias(time, $__interval), 
    ROUND(PAPP * $cosphi / 5) * 5 AS "Puissance apparente" 
FROM linky.linky_realtime 
WHERE $__timeFilter(time)
```

---

### 2. Consommation Journalière (Comparaison Jour Actuel vs Base)

**❌ Avant (lent - scan de 2 tables)** :
```sql
(SELECT
    "current",
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total_kwh
FROM linky_realtime
WHERE time >= NOW() - INTERVAL 1 DAY)
UNION
(SELECT 
    "base",
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / $nb_days_period / 1000 as total_kwh
FROM linky_history
WHERE time >= NOW() - INTERVAL $nb_days_period DAY)
```

**✅ Après (rapide - tables agrégées)** :
```sql
(SELECT
    "current" as label,
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total_kwh
FROM linky_realtime
WHERE time >= NOW() - INTERVAL 1 DAY)
UNION
(SELECT 
    "base" as label,
    AVG(total_kwh) as total_kwh
FROM linky_daily
WHERE date >= CURDATE() - INTERVAL $nb_days_period DAY)
```

**Gain** : ~10-20x plus rapide (pas de calcul MIN/MAX sur linky_history)

---

### 3. Consommation Mensuelle (Vue Longue Durée)

**❌ Avant (très lent - window functions sur 61k rows)** :
```sql
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-$jour_releve_compteur 00:00:00')) as timestamp,
    (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_kwh_HCHP,
    (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh_HCHC
FROM linky_history
WHERE time >= NOW() - INTERVAL $nb_days_period DAY
UNION
(SELECT
    time as timestamp, 
    IFNULL(counter_HCHP - LAG(counter_HCHP) OVER (ORDER BY time), 0) AS total_kwh_HCHP,
    IFNULL(counter_HCHC - LAG(counter_HCHC) OVER (ORDER BY time), 0) AS total_kwh_HCHC
FROM (
    SELECT time, HCHP / 1000 as counter_HCHP, HCHC / 1000 as counter_HCHC 
    FROM linky_history
    WHERE DAY(time) = $jour_releve_compteur AND HOUR(time) = 0
) as A)
ORDER BY timestamp
```

**✅ Après (très rapide - table linky_monthly)** :
```sql
SELECT
    billing_month as time,
    hchp_kwh as "HP",
    hchc_kwh as "HC"
FROM linky_monthly
WHERE billing_month >= DATE_FORMAT(NOW() - INTERVAL $nb_days_period DAY, '%Y-%m-$jour_releve_compteur')
ORDER BY billing_month
```

**Gain** : ~500-1000x plus rapide (84 rows vs 61k + window functions)

---

### 4. Température Moyenne Mensuelle

**❌ Avant (lent - GROUP BY sur table complète)** :
```sql
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-$jour_releve_compteur 00:00:00')) as timestamp,
    ROUND(AVG(temperature), 1) as Temperature
FROM linky.linky_history
GROUP BY MONTH(time), YEAR(time)
```

**✅ Après (rapide - table pré-agrégée)** :
```sql
SELECT
    billing_month as time,
    avg_temp as Temperature
FROM linky_monthly
WHERE billing_month >= $__timeFrom()
  AND billing_month <= $__timeTo()
ORDER BY billing_month
```

---

### 5. Évolution Annuelle (Graphique Multi-Années)

**❌ Avant (très lent)** :
```sql
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-$jour_releve_compteur 00:00:00')) as time,
    (MAX(HCHP) - MIN(HCHP)) / 1000 AS total_kwh_HCHP,
    (MAX(HCHC) - MIN(HCHC)) / 1000 AS total_kwh_HCHC
FROM linky_history
WHERE time BETWEEN NOW() - INTERVAL 3 YEAR AND NOW()
UNION
(SELECT
    time, 
    IFNULL(counter_HCHP - LAG(counter_HCHP) OVER (ORDER BY time), 0) AS total_kwh_HCHP,
    IFNULL(counter_HCHC - LAG(counter_HCHC) OVER (ORDER BY time), 0) AS total_kwh_HCHC
FROM (
    SELECT time, HCHP / 1000 as counter_HCHP, HCHC / 1000 as counter_HCHC 
    FROM linky_history
    WHERE DAY(time) = $jour_releve_compteur 
      AND MONTH(time) = 12 
      AND HOUR(time) = 0
) as A)
ORDER BY time
```

**✅ Après (très rapide)** :
```sql
SELECT
    billing_month as time,
    hchp_kwh,
    hchc_kwh,
    total_kwh
FROM linky_monthly
WHERE billing_month >= NOW() - INTERVAL 3 YEAR
ORDER BY billing_month
```

**Gain** : ~1000x plus rapide

---

### 6. Comparaison Période Actuelle vs Période Passée

**❌ Avant (lent)** :
```sql
(SELECT 
    "current",
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total
FROM linky_history
WHERE time BETWEEN NOW() - INTERVAL $nb_days_period DAY AND NOW())
UNION
(SELECT 
    "base",
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total
FROM linky_history
WHERE time BETWEEN NOW() - INTERVAL $nb_days_period DAY - INTERVAL 1 DAY 
                     AND NOW() - INTERVAL 1 DAY)
```

**✅ Après (rapide)** :
```sql
(SELECT 
    "current" as period,
    SUM(total_kwh) as total
FROM linky_daily
WHERE date >= CURDATE() - INTERVAL $nb_days_period DAY)
UNION
(SELECT 
    "previous" as period,
    SUM(total_kwh) as total
FROM linky_daily
WHERE date BETWEEN CURDATE() - INTERVAL ($nb_days_period * 2) DAY 
               AND CURDATE() - INTERVAL $nb_days_period DAY - INTERVAL 1 DAY)
```

---

### 7. Consommation Moyenne par Jour de la Semaine

**❌ Avant (lent - agrégation complexe)** :
```sql
SELECT
    DAYNAME(DATE(time)) as day_name,
    AVG((MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000) as avg_kwh
FROM linky_history
WHERE time >= NOW() - INTERVAL 90 DAY
GROUP BY DATE(time), DAYOFWEEK(time)
GROUP BY DAYOFWEEK(time)
```

**✅ Après (rapide - agrégation sur table daily)** :
```sql
SELECT
    DAYNAME(date) as day_name,
    AVG(total_kwh) as avg_kwh
FROM linky_daily
WHERE date >= CURDATE() - INTERVAL 90 DAY
GROUP BY DAYOFWEEK(date)
ORDER BY DAYOFWEEK(date)
```

---

### 8. Heatmap Consommation par Heure (Vue Semaine)

**❌ Avant (utilise linky_history - acceptable)** :
```sql
SELECT
    $__timeGroupAlias(time, 1h),
    AVG((HCHP + HCHC)) as consumption
FROM linky_history
WHERE $__timeFilter(time)
  AND time >= NOW() - INTERVAL 7 DAY
GROUP BY HOUR(time), DATE(time)
```

**✅ Après (optimisé avec index)** :
```sql
-- Même requête mais bénéficie de l'index idx_history_time
SELECT
    $__timeGroupAlias(time, 1h),
    AVG((HCHP + HCHC)) as consumption
FROM linky_history
WHERE $__timeFilter(time)
  AND time >= NOW() - INTERVAL 7 DAY
GROUP BY HOUR(time), DATE(time)
```

**Alternative pour vue mensuelle** :
```sql
SELECT
    date as time,
    total_kwh
FROM linky_daily
WHERE date >= CURDATE() - INTERVAL 30 DAY
ORDER BY date
```

---

## 🔄 Dashboard Adaptatif (Requête Dynamique)

Pour créer un dashboard qui s'adapte automatiquement selon la plage de temps sélectionnée :

```sql
-- Utilise UNION pour combiner plusieurs sources selon la période
SELECT 
    time,
    total_kwh
FROM (
    -- Temps réel (< 2 jours)
    SELECT 
        time,
        (HCHP + HCHC) / 1000 as total_kwh
    FROM linky_realtime
    WHERE $__timeFilter(time)
      AND TIMESTAMPDIFF(HOUR, $__timeFrom(), $__timeTo()) <= 48
    
    UNION ALL
    
    -- Vue quotidienne (2-90 jours)
    SELECT 
        TIMESTAMP(date) as time,
        total_kwh
    FROM linky_daily
    WHERE date >= DATE($__timeFrom())
      AND date <= DATE($__timeTo())
      AND TIMESTAMPDIFF(DAY, $__timeFrom(), $__timeTo()) > 2
      AND TIMESTAMPDIFF(DAY, $__timeFrom(), $__timeTo()) <= 90
    
    UNION ALL
    
    -- Vue mensuelle (> 90 jours)
    SELECT 
        TIMESTAMP(billing_month) as time,
        total_kwh
    FROM linky_monthly
    WHERE billing_month >= DATE($__timeFrom())
      AND billing_month <= DATE($__timeTo())
      AND TIMESTAMPDIFF(DAY, $__timeFrom(), $__timeTo()) > 90
) as combined_data
ORDER BY time
```

---

## 📊 Variables Grafana Recommandées

### Variable: jour_releve_compteur (existante)
```
Type: Textbox
Default: 24
Description: Jour de relevé du compteur électrique
```

### Variable: nb_days_period (mise à jour)
```sql
-- Calcul du nombre de jours dans la période de facturation
SELECT
    CASE WHEN DAYOFMONTH(CURRENT_DATE) <= $jour_releve_compteur
    THEN 
        DAYOFMONTH(LAST_DAY(DATE_ADD(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH), 
                                      INTERVAL $jour_releve_compteur - DAYOFMONTH(CURRENT_DATE) DAY)))
    ELSE
        DAYOFMONTH(LAST_DAY(DATE_ADD(CURRENT_DATE, 
                                      INTERVAL $jour_releve_compteur - DAYOFMONTH(CURRENT_DATE) DAY)))
    END
```

### Variable: optimization_mode (nouvelle)
```sql
-- Détecte automatiquement la table optimale
SELECT 
    CASE 
        WHEN TIMESTAMPDIFF(HOUR, $__timeFrom(), $__timeTo()) <= 48 THEN 'realtime'
        WHEN TIMESTAMPDIFF(DAY, $__timeFrom(), $__timeTo()) <= 90 THEN 'daily'
        ELSE 'monthly'
    END as mode
```

---

## 🎨 Templates de Panels Optimisés

### Panel: Consommation Mensuelle (Bar Chart)

**Configuration** :
- Visualization: Bar Chart
- Data source: MySQL
- Query:

```sql
SELECT
    billing_month as time,
    hchp_kwh as "Heures Pleines",
    hchc_kwh as "Heures Creuses",
    total_kwh as "Total"
FROM linky_monthly
WHERE billing_month >= NOW() - INTERVAL 1 YEAR
ORDER BY billing_month
```

- Format as: Time series
- Legend: Show, Bottom
- Stacking: Normal

### Panel: Tendance Annuelle (Time Series)

**Configuration** :
- Visualization: Time series
- Data source: MySQL
- Query:

```sql
SELECT
    billing_month as time,
    total_kwh,
    avg_temp as temperature
FROM linky_monthly
WHERE year_val >= YEAR(NOW()) - 3
ORDER BY billing_month
```

- Right Y-axis: temperature (°C)
- Left Y-axis: total_kwh (kWh)

### Panel: Comparaison Quotidienne (Stat)

**Configuration** :
- Visualization: Stat
- Data source: MySQL
- Query:

```sql
SELECT
    "today" as metric,
    (SELECT 
        (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000
     FROM linky_realtime
     WHERE time >= CURDATE()) as value
UNION
SELECT
    "yesterday" as metric,
    total_kwh as value
FROM linky_daily
WHERE date = CURDATE() - INTERVAL 1 DAY
UNION
SELECT
    "avg_month" as metric,
    AVG(total_kwh) as value
FROM linky_daily
WHERE date >= CURDATE() - INTERVAL 30 DAY
```

- Orientation: Horizontal
- Graph mode: None
- Color mode: Value

---

## 🧪 Test des Performances

### Benchmark Query (à exécuter dans MySQL Workbench ou CLI)

```sql
-- Test 1: Vue mensuelle AVANT optimisation
SET @start = NOW(6);
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-24 00:00:00')) as timestamp,
    (MAX(HCHP) - MIN(HCHP)) / 1000 AS hchp_kwh
FROM linky_history
WHERE time >= NOW() - INTERVAL 1 YEAR
GROUP BY MONTH(time), YEAR(time);
SELECT TIMESTAMPDIFF(MICROSECOND, @start, NOW(6)) / 1000 as 'Duration (ms)';

-- Test 2: Vue mensuelle APRÈS optimisation
SET @start = NOW(6);
SELECT
    billing_month as time,
    hchp_kwh
FROM linky_monthly
WHERE billing_month >= NOW() - INTERVAL 1 YEAR
ORDER BY billing_month;
SELECT TIMESTAMPDIFF(MICROSECOND, @start, NOW(6)) / 1000 as 'Duration (ms)';
```

**Résultats attendus** :
- Avant : 2000-5000 ms
- Après : 5-20 ms
- **Gain : 100-1000x**

---

## 🎯 Checklist Migration Dashboard

- [ ] Identifier les requêtes qui utilisent `GROUP BY MONTH(time), YEAR(time)`
- [ ] Remplacer par requêtes sur `linky_monthly`
- [ ] Identifier les requêtes avec `INTERVAL > 30 DAY`
- [ ] Remplacer par `linky_daily` ou `linky_monthly` selon la période
- [ ] Vérifier que les requêtes temps réel (< 2j) utilisent `linky_realtime`
- [ ] Tester chaque panel avec une plage de 7 ans de données
- [ ] Vérifier la cohérence des valeurs (comparaison avant/après)
- [ ] Activer le cache Grafana (Query caching: 1 min pour queries optimisées)
- [ ] Documenter les modifications dans le dashboard (annotations)

---

## 📚 Ressources

- [Grafana MySQL Data Source](https://grafana.com/docs/grafana/latest/datasources/mysql/)
- [Grafana Query Inspector](https://grafana.com/docs/grafana/latest/panels/inspect-panel/)
- [MySQL EXPLAIN](https://dev.mysql.com/doc/refman/8.0/en/explain.html) pour analyser les plans d'exécution

---

## 💡 Bonnes Pratiques

1. **Toujours utiliser les index** : Les colonnes `time`, `date`, `billing_month` sont indexées
2. **Éviter les window functions** sur grandes tables : Utilisez les tables agrégées
3. **Limiter les UNION** : Préférez une seule table agrégée quand possible
4. **Utiliser DATE() pour comparaisons** : Plus rapide que `YEAR()` + `MONTH()`
5. **Activer le cache Grafana** : 60 secondes pour les queries sur tables agrégées
6. **Monitorer les performances** : Utiliser Query Inspector pour voir les temps d'exécution

---

## ❓ FAQ

**Q: Mes anciens dashboards vont-ils casser ?**  
R: Non, les tables `linky_realtime` et `linky_history` restent inchangées.

**Q: Dois-je modifier TOUS mes panels ?**  
R: Non, seulement ceux qui sont lents (typiquement vues > 30 jours).

**Q: Comment savoir quels panels optimiser ?**  
R: Utilisez Query Inspector (icône panel → Inspect → Query) pour voir les temps d'exécution.

**Q: Les agrégations automatiques de Grafana fonctionnent-elles ?**  
R: Oui, mais elles sont maintenant plus rapides car les données sources sont pré-agrégées.

**Q: Puis-je mixer plusieurs tables dans un panel ?**  
R: Oui, utilisez UNION ALL pour combiner `linky_realtime` + `linky_daily` par exemple.
