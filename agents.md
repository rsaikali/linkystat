# Agents LinkyStats

## Vue d'ensemble

Ce document décrit les agents Python utilisés dans le projet LinkyStats pour la collecte et le traitement des données de consommation électrique.

## Architecture des agents

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Compteur      │───▶│  Agent LinkyData │───▶│   Base MySQL    │
│   Linky (USB)   │    │  (collecteur)    │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │ Agent Weather    │
                       │ (température)    │
                       └──────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │  API OpenWeather │
                       └──────────────────┘
```

## Agents disponibles

### 1. LinkyData Agent (`src/linky2db.py`)

**Type** : Agent de collecte temps réel  
**Responsabilité** : Lecture des données TéléInfo depuis le compteur Linky

#### Configuration requise

La configuration se fait via un fichier '.env' à la racine du projet.

#### Données collectées via l'USB TéléInfo
- `PAPP` : Puissance apparente instantanée (W)
- `HCHC` : Index heures creuses (Wh)
- `HCHP` : Index heures pleines (Wh)
- `LTARF` : Libellé tarif en cours
- `DATE` : Horodatage des données

#### Cycle de fonctionnement
1. Connexion au port série USB
2. Lecture continue des trames TéléInfo
3. Validation des checksums
4. Enrichissement avec données météo
5. Stockage en base MySQL

### 2. LinkyDataFromProd Agent (`src/linky2db.py`)

**Type** : Agent de synchronisation utilisé uniquement en développement.  
**Responsabilité** : Réplication des données depuis l'environnement de production

#### Configuration requise

La configuration se fait via un fichier '.env' à la racine du projet.

#### Cycle de fonctionnement
1. Polling de la base de production
2. Détection de nouvelles données
3. Réplication vers base de développement
4. Gestion des doublons

### 3. TemperatureManager Agent (`src/weather.py`)

**Type** : Agent d'enrichissement  
**Responsabilité** : Collecte des données météorologiques via l'API OpenWeather.

#### Configuration requise

La configuration se fait via un fichier '.env' à la racine du projet.

#### Fonctionnalités
- Cache TTL de 10 minutes
- Appels API optimisés
- Gestion des erreurs réseau

## Monitoring et supervision

### Métriques de santé

Chaque agent expose des métriques de santé :
- Nombre de paquets traités
- Taux d'erreurs
- Timestamp dernière donnée
- Statut de connexion

### Logs structurés

Format standard : `[YYYY-MM-DD HH:MM:SS LEVEL/module] message`

```python
[2025-09-18 10:15:23 INFO/linky2db] Received new packet from '/dev/ttyUSB0' Linky device [PAPP=2450 HCHP=12345678 HCHC=9876543 LTARF=HP..]
[2025-09-18 10:15:23 INFO/weather] Calling OpenWeather API for current temperature: 18.5°C
```

## Déploiement

### Mode Production

Le déploiement en production se fait via les Github actions CI/CD qui se trouvent sous `.github/workflows`.

### Mode Développement

Le déploiement en développement se fait via le devcontainer Docker VSCode.

## Bonnes pratiques

### Développement
- Respect des conventions PEP8 via l'outil black
- Tests unitaires avec pytest
- Documentation avec docstrings en anglais

### Gestion d'erreurs
- Retry automatique avec backoff exponentiel
- Logging détaillé des erreurs
- Graceful shutdown sur SIGTERM

### Performance
- Connexions persistantes à la base
- Batch processing pour les insertions
- Cache pour les appels API externes

### Sécurité
- Validation stricte des données d'entrée
- Requêtes SQL paramétrées
- Gestion sécurisée des secrets
