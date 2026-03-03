# Migration vers le Schéma Optimisé LinkyStats

## 🎯 Objectif

Améliorer les performances Grafana en pré-calculant les agrégations quotidiennes et mensuelles au lieu de les calculer à chaque requête. Sur 7 ans de données (~61 000 lignes horaires), les requêtes complexes peuvent prendre plusieurs secondes. Avec les tables agrégées, le temps de réponse passe à quelques millisecondes.

## 📊 Architecture

### Tables Originales
- **linky_realtime** : Données temps réel (~1/sec), rétention 2 jours
- **linky_history** : Données horaires, conservation illimitée (~61k rows sur 7 ans)

### Nouvelles Tables Agrégées
- **linky_daily** : Agrégation journalière (1 row par jour = ~2 555 rows sur 7 ans)
- **linky_monthly** : Agrégation mensuelle par période de facturation (1 row par mois = ~84 rows sur 7 ans)

### Gain de Performance Estimé

| Vue Grafana | Avant | Après | Gain |
|-------------|-------|-------|------|
| Temps réel (< 2j) | **~100ms** | ~100ms | 1x |
| Semaine/Mois | **2-5s** | ~50ms | **40-100x** |
| Année | **5-15s** | ~10ms | **500-1500x** |
| Multi-années | **15-30s** | ~20ms | **750-1500x** |

### Optimisations Implémentées

1. **Index sur colonnes de temps** : Accélère les filtres `WHERE time >= ...`
2. **Tables agrégées pré-calculées** : Plus besoin de `GROUP BY` sur 61k rows
3. **Procédures stockées MySQL** : Calculs automatisés et maintenables
4. **MySQL Events** : Mise à jour automatique (quotidienne à 1h, horaire pour jour courant)
5. **Gestion native du jour de relevé** : Supporte les périodes de facturation custom (ex: du 24/01 au 23/02)

---

## 🚀 Procédure de Migration

### Prérequis

- Docker et Docker Compose installés
- Fichier `.env` configuré avec variables MySQL
- Backup de la base de données (recommandé)

### Étape 1 : Backup de Sécurité

```bash
# Créer un backup avant migration
./scripts/mysql_backup.sh

# Vérifier que le fichier backup existe
ls -lh linkystat_mysql_backup.sql.gz
```

### Étape 2 : Arrêter les Services

```bash
cd /app  # ou le répertoire racine du projet
docker compose --env-file .env down
```

### Étape 3 : Remplacer le Script d'Initialisation

```bash
# Renommer l'ancien script (backup)
mv files/mysql/init-script.sh files/mysql/init-script.old.sh

# Activer le nouveau script optimisé
mv files/mysql/init-script-optimized.sh files/mysql/init-script.sh
```

**Important** : Si la base de données existe déjà, les `CREATE TABLE IF NOT EXISTS` ne feront rien. Le nouveau schéma sera appliqué uniquement pour les nouvelles tables (linky_daily, linky_monthly) et les procédures/events.

### Étape 4 : Redémarrer les Services

```bash
docker compose --env-file .env up -d
```

### Étape 5 : Exécuter la Migration des Données

```bash
# Rendre le script exécutable
chmod +x scripts/migrate_to_optimized_schema.sh

# Lancer la migration (remplacer 24 par votre jour de relevé si différent)
./scripts/migrate_to_optimized_schema.sh 24
```

**Durée estimée** : 
- 1 an de données : ~30 secondes
- 7 ans de données : ~3-5 minutes

**Sortie attendue** :
```
=========================================
   LinkyStats Schema Migration Tool
=========================================

Meter reading day: 24

[INFO] Loading environment from .env file...
[INFO] Connected to MySQL container: linky2db-mysql-1

[STEP 1/5] Analyzing existing data...
min_date    max_date    total_rows  days_span
2018-01-01  2025-03-03  61320       2618

[INFO] Data range: 2018-01-01 to 2025-03-03
[INFO] Total rows: 61320 (2618 days)

[STEP 2/5] Populating daily aggregates...
[INFO] This may take several minutes for 2618 days...
[SUCCESS] Created 2618 daily aggregates

[STEP 3/5] Populating monthly aggregates...
[INFO] Using billing day: 24
[INFO] Processing period 84/84: 2025-02-24...
[SUCCESS] Created 84 monthly aggregates

[STEP 4/5] Verifying data integrity...
table_name  rows  min_date    max_date
Daily       2618  2018-01-01  2025-03-03
Monthly     84    2018-01-24  2025-02-24

[STEP 5/5] Sample aggregated data:
--- Latest daily data ---
date        consumption  temp      data_points
2025-03-03  18.45 kWh    12.3°C    24
2025-03-02  21.12 kWh    10.8°C    24
...

--- Latest monthly data ---
billing_month  consumption  temp      days
2025-02-24     587.23 kWh   8.5°C    31
2025-01-24     623.45 kWh   6.2°C    31
...

=========================================
   Migration completed successfully!
=========================================
```

### Étape 6 : Vérifier les MySQL Events

```bash
# Lister les events actifs
docker exec linky2db-mysql-1 mysql \
  -u root -p${MYSQL_ROOT_PASSWORD} \
  -e "SHOW EVENTS FROM linky;"
```

**Events attendus** :
- `clean_realtime` : Nettoyage des données temps réel (chaque minute)
- `refresh_daily_aggregates` : Mise à jour quotidienne (1h du matin)
- `refresh_current_day_aggregate` : Mise à jour du jour en cours (chaque heure)

---

## 📝 Structure des Tables Agrégées

### Table `linky_daily`

Stocke les consommations quotidiennes (minuit à minuit).

```sql
CREATE TABLE linky_daily (
    date DATE PRIMARY KEY,                -- Date du jour
    hchp_start INTEGER UNSIGNED,          -- Compteur HCHP début de journée
    hchp_end INTEGER UNSIGNED,            -- Compteur HCHP fin de journée
    hchc_start INTEGER UNSIGNED,          -- Compteur HCHC début de journée
    hchc_end INTEGER UNSIGNED,            -- Compteur HCHC fin de journée
    hchp_kwh DECIMAL(10,3),               -- Consommation HCHP en kWh
    hchc_kwh DECIMAL(10,3),               -- Consommation HCHC en kWh
    total_kwh DECIMAL(10,3),              -- Consommation totale en kWh
    avg_temp DECIMAL(5,2),                -- Température moyenne
    min_temp DECIMAL(5,2),                -- Température minimale
    max_temp DECIMAL(5,2),                -- Température maximale
    data_points INTEGER UNSIGNED,         -- Nombre de points horaires
    INDEX idx_daily_date (date)
);
```

### Table `linky_monthly`

Stocke les consommations par période de facturation (ex: du 24/01 au 23/02).

```sql
CREATE TABLE linky_monthly (
    billing_month DATE PRIMARY KEY,       -- Date de relevé (ex: 2025-01-24)
    year_val SMALLINT UNSIGNED,           -- Année
    month_val TINYINT UNSIGNED,           -- Mois
    reading_day TINYINT UNSIGNED,         -- Jour de relevé (ex: 24)
    hchp_start INTEGER UNSIGNED,          -- Compteur HCHP début période
    hchp_end INTEGER UNSIGNED,            -- Compteur HCHP fin période
    hchc_start INTEGER UNSIGNED,          -- Compteur HCHC début période
    hchc_end INTEGER UNSIGNED,            -- Compteur HCHC fin période
    hchp_kwh DECIMAL(10,3),               -- Consommation HCHP en kWh
    hchc_kwh DECIMAL(10,3),               -- Consommation HCHC en kWh
    total_kwh DECIMAL(10,3),              -- Consommation totale en kWh
    avg_temp DECIMAL(5,2),                -- Température moyenne
    min_temp DECIMAL(5,2),                -- Température minimale
    max_temp DECIMAL(5,2),                -- Température maximale
    nb_days INTEGER UNSIGNED,             -- Durée de la période (jours)
    data_points INTEGER UNSIGNED,         -- Nombre de points de données
    INDEX idx_monthly_year_month (year_val, month_val)
);
```

---

## 🔄 Mise à Jour Automatique

### Events MySQL Configurés

1. **clean_realtime** (chaque minute)
   ```sql
   DELETE FROM linky_realtime WHERE time < NOW() - INTERVAL 2 DAY;
   ```

2. **refresh_daily_aggregates** (chaque jour à 1h)
   ```sql
   CALL refresh_daily_aggregate(CURDATE() - INTERVAL 1 DAY);
   CALL refresh_daily_aggregate(CURDATE() - INTERVAL 2 DAY);
   ```

3. **refresh_current_day_aggregate** (chaque heure)
   ```sql
   CALL refresh_daily_aggregate(CURDATE());
   ```

### Mise à Jour Manuelle

Si besoin de recalculer manuellement :

```bash
# Recalculer une journée spécifique
docker exec -i linky2db-mysql-1 mysql -u root -p${MYSQL_ROOT_PASSWORD} linky <<EOF
CALL refresh_daily_aggregate('2025-03-03');
EOF

# Recalculer un mois spécifique (jour de relevé = 24)
docker exec -i linky2db-mysql-1 mysql -u root -p${MYSQL_ROOT_PASSWORD} linky <<EOF
CALL refresh_monthly_aggregate('2025-02-24', 24);
EOF
```

---

## 📈 Exemples de Requêtes Grafana Optimisées

### Avant Optimisation (lent sur 7 ans)

```sql
-- Vue mensuelle : scan complet de linky_history (61k rows)
SELECT
    time,
    IFNULL(counter_HCHP - LAG(counter_HCHP) OVER (ORDER BY time), 0) AS total_kwh_HCHP
FROM (
    SELECT time, HCHP / 1000 as counter_HCHP FROM linky_history
    WHERE DAY(time) = $jour_releve_compteur AND HOUR(time) = 0
) as A
```

### Après Optimisation (rapide)

```sql
-- Vue mensuelle : scan de linky_monthly (84 rows)
SELECT
    billing_month as time,
    hchp_kwh
FROM linky_monthly
WHERE billing_month >= $__timeFrom()
  AND billing_month <= $__timeTo()
ORDER BY billing_month
```

### Exemples Complets

#### 1. Consommation Journalière (derniers 30 jours)

**Avant** :
```sql
SELECT 
    DATE(time) as time,
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total_kwh
FROM linky_history
WHERE time >= NOW() - INTERVAL 30 DAY
GROUP BY DATE(time)
```

**Après** :
```sql
SELECT 
    date as time,
    total_kwh
FROM linky_daily
WHERE date >= NOW() - INTERVAL 30 DAY
ORDER BY date
```

#### 2. Consommation Mensuelle (dernière année)

**Avant** :
```sql
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-$jour_releve_compteur 00:00:00')) as time,
    (MAX(HCHP) - MIN(HCHP)) / 1000 AS hchp_kwh,
    (MAX(HCHC) - MIN(HCHC)) / 1000 AS hchc_kwh
FROM linky_history
GROUP BY YEAR(time), MONTH(time)
```

**Après** :
```sql
SELECT
    billing_month as time,
    hchp_kwh,
    hchc_kwh
FROM linky_monthly
WHERE billing_month >= NOW() - INTERVAL 1 YEAR
ORDER BY billing_month
```

#### 3. Température Moyenne Mensuelle

**Avant** :
```sql
SELECT
    TIMESTAMP(DATE_FORMAT(MAX(time), '%Y-%m-$jour_releve_compteur 00:00:00')) as time,
    ROUND(AVG(temperature), 1) as temperature
FROM linky_history
GROUP BY MONTH(time), YEAR(time)
```

**Après** :
```sql
SELECT
    billing_month as time,
    avg_temp as temperature
FROM linky_monthly
WHERE billing_month >= $__timeFrom()
ORDER BY billing_month
```

#### 4. Vue Temps Réel (< 2 jours) - **INCHANGÉ**

```sql
-- Continue d'utiliser linky_realtime pour les données temps réel
SELECT
    time,
    PAPP,
    temperature
FROM linky_realtime
WHERE $__timeFilter(time)
ORDER BY time
```

---

## 🛠️ Maintenance

### Vérifier l'Intégrité des Données

```bash
# Comparer les agrégations avec les données brutes
docker exec -i linky2db-mysql-1 mysql -u root -p${MYSQL_ROOT_PASSWORD} linky <<EOF
-- Vérifier cohérence jour spécifique
SELECT 
    'linky_history' as source,
    (MAX(HCHP) - MIN(HCHP) + MAX(HCHC) - MIN(HCHC)) / 1000 as total_kwh
FROM linky_history
WHERE DATE(time) = '2025-03-01'
UNION ALL
SELECT 
    'linky_daily' as source,
    total_kwh
FROM linky_daily
WHERE date = '2025-03-01';
EOF
```

### Reconstruire les Agrégations

Si les données sont incohérentes :

```bash
# Supprimer et recréer les agrégations
docker exec -i linky2db-mysql-1 mysql -u root -p${MYSQL_ROOT_PASSWORD} linky <<EOF
TRUNCATE TABLE linky_daily;
TRUNCATE TABLE linky_monthly;
EOF

# Relancer la migration
./scripts/migrate_to_optimized_schema.sh 24
```

### Monitoring des Performances

```bash
# Taille des tables
docker exec -i linky2db-mysql-1 mysql -u root -p${MYSQL_ROOT_PASSWORD} linky <<EOF
SELECT 
    table_name,
    ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb,
    table_rows
FROM information_schema.TABLES
WHERE table_schema = 'linky'
ORDER BY (data_length + index_length) DESC;
EOF
```

**Résultat attendu après 7 ans** :
```
table_name       size_mb  table_rows
linky_history    ~15 MB   61320
linky_daily      ~1 MB    2618
linky_monthly    ~0.05 MB 84
linky_realtime   ~0.5 MB  ~2880 (2 jours)
```

---

## 🔧 Rollback (Si Problème)

En cas de problème, revenir à l'ancien schéma :

```bash
# 1. Arrêter les services
docker compose --env-file .env down

# 2. Restaurer l'ancien script
mv files/mysql/init-script.sh files/mysql/init-script-optimized.sh
mv files/mysql/init-script.old.sh files/mysql/init-script.sh

# 3. Restaurer le backup
./scripts/mysql_restore.sh linkystat_mysql_backup.sql.gz

# 4. Redémarrer
docker compose --env-file .env up -d
```

---

## 📚 Ressources

- [Documentation MySQL Events](https://dev.mysql.com/doc/refman/8.0/en/events.html)
- [Stored Procedures MySQL](https://dev.mysql.com/doc/refman/8.0/en/stored-routines.html)
- [Grafana MySQL Data Source](https://grafana.com/docs/grafana/latest/datasources/mysql/)

---

## ❓ FAQ

**Q: Les données temps réel sont-elles impactées ?**  
R: Non, la table `linky_realtime` fonctionne exactement comme avant.

**Q: Dois-je modifier mon code Python ?**  
R: Non, `linky2db.py` continue d'écrire dans `linky_realtime` et le trigger alimente `linky_history` comme avant.

**Q: Puis-je changer le jour de relevé après migration ?**  
R: Oui, relancez `migrate_to_optimized_schema.sh` avec le nouveau jour.

**Q: Combien d'espace disque supplémentaire ?**  
R: ~1 MB pour 7 ans de données (négligeable).

**Q: Les agrégations manuelles dans Grafana fonctionnent-elles encore ?**  
R: Oui, mais elles seront beaucoup plus rapides car les tables agrégées sont indexées.

**Q: Que se passe-t-il si je modifie des données historiques ?**  
R: Relancez `CALL refresh_daily_aggregate('YYYY-MM-DD')` pour recalculer le jour concerné.
