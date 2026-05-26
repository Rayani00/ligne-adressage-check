# ligne-adressage-check

Vérifie l'enregistrement d'un participant (par son SIREN) sur trois systèmes :

1. **Peppol** — résolution SML/SMP et récupération des informations d'Access Point.
2. **Harmony-connector** — contrôle que le routage du participant est en place.
3. **legalRef** — récupération de la ligne d'annuaire associée au SIREN.

Le script déduit automatiquement l'environnement (`uat`, `pre`, `prd`) et le PA
(`gnx`, `fulll`, `pitney-bowes`, `pytheas`, …) à partir des informations Peppol.

Deux modes d'exécution :

- **Mono-SIREN** — sortie console (DEBUG ou ERROR_ONLY).
- **Batch** — entrée multi-SIRENs (fichier ou liste CLI) et génération d'un **rapport Markdown** incluant l'URL et le payload de chaque requête HTTP effectuée (secrets redactés). Disponible sur les deux versions (PowerShell et Bash).

## Contenu du dépôt

| Fichier                 | Description                                                        |
|-------------------------|--------------------------------------------------------------------|
| `ligne_full_check.ps1`  | Version Windows / PowerShell (aucune dépendance externe). Supporte le mode batch + rapport Markdown. |
| `ligne_full_check.sh`   | Version Bash / Linux (requiert `curl`, `jq`, `base32`, `xmllint`, `openssl`, `dig`). Supporte le mode batch + rapport Markdown. |
| `run.cmd`               | Lanceur Windows interactif pour le script PowerShell (mono-SIREN). |
| `script.env.example`    | Modèle de configuration des secrets.                               |

## Configuration

Les scripts ont besoin de quatre secrets. Copiez le modèle et renseignez vos valeurs :

```sh
cp script.env.example script.env
```

`script.env` est ignoré par git et ne doit **jamais** être committé. Les fichiers
locaux `sirens.txt` et `rapport*.md` sont également exclus du dépôt
(ils peuvent contenir des identifiants ou URLs internes).

## Utilisation

### Mode mono-SIREN

**Windows (PowerShell)** — via le lanceur interactif :

```bat
run.cmd 432526903_TESTPILOTE
run.cmd 432526903_TESTPILOTE false   :: mode ERROR_ONLY
```

Ou directement :

```powershell
.\ligne_full_check.ps1 432526903_TESTPILOTE
```

**Linux / macOS (Bash)** :

```sh
. ./script.env
./ligne_full_check.sh 432526903_TESTPILOTE
./ligne_full_check.sh 432526903_TESTPILOTE false   # mode ERROR_ONLY
```

Le second argument contrôle le mode d'affichage :

- `true` (défaut) — mode DEBUG, affiche toutes les informations ;
- `false` — mode ERROR_ONLY, n'affiche que les erreurs.

### Mode batch

Préparez une liste de SIRENs dans un fichier texte, une ligne par SIREN. Le
script tolère les formats bruités :

- parenthèses de fin (`645680026_TESTPILOTE (Delpeyrat)`)
- texte préfixe (`INVICTA GROUP  785520180_TESTPILOTE`)
- espace parasite avant `_` (`335186094 _TESTPILOTE`)
- lignes vides et commentaires `#`

Doublons dédupliqués automatiquement. Lignes non reconnues listées en fin
d'exécution.

**Windows (PowerShell)** :

```powershell
# Avec fichier d'entrée
.\ligne_full_check.ps1 -InputFile .\sirens.txt -OutputMarkdown .\rapport.md

# Avec liste CLI
.\ligne_full_check.ps1 -Sirens 391282597_TESTPILOTE,534980537_TESTPILOTE -OutputMarkdown .\rapport.md

# Avec nom de rapport horodaté
.\ligne_full_check.ps1 -InputFile .\sirens.txt -OutputMarkdown ".\rapport_$(Get-Date -f yyyyMMdd_HHmm).md"
```

Si `-ExecutionPolicy` est restrictive :

```powershell
powershell -ExecutionPolicy Bypass -File .\ligne_full_check.ps1 -InputFile .\sirens.txt -OutputMarkdown .\rapport.md
```

**Linux / macOS (Bash)** :

```sh
# Avec fichier d'entrée
./ligne_full_check.sh -i sirens.txt -o rapport.md

# Avec liste CLI
./ligne_full_check.sh -s 391282597_TESTPILOTE,534980537_TESTPILOTE -o rapport.md

# Avec nom de rapport horodaté
./ligne_full_check.sh -i sirens.txt -o "rapport_$(date +%Y%m%d_%H%M).md"
```

Les options longues `--input-file`, `--sirens`, `--output-markdown` sont aussi
acceptées. `script.env` est chargé automatiquement s'il se trouve à côté du
script (`source ./script.env` reste possible).

### Contenu du rapport Markdown

Le rapport généré contient :

1. **En-tête** : date, total de SIRENs traités, nombre de verts (3 checks OK) et de KO.
2. **Tableau résumé** : une ligne par SIREN avec colonnes `Peppol | Harmony | LegalRef | ENV | PA`.
3. **Section "Details"** : un bloc par SIREN avec, pour chaque check :
   - le statut (`OK`, `ERROR`, `N/A`, `NOT_RUN`) ;
   - la liste des **requêtes HTTP effectuées** (méthode + URL, body et header sanitisés — `client_secret=***`, `Bearer <token>`) ;
   - le JSON de réponse ou le message d'erreur exact.

Les requêtes capturées permettent de reproduire manuellement un check en
`curl` / Postman pour debugger (voir exemples ci-dessous).

### Reproduire une requête depuis le rapport

**Peppol (pas d'auth, ouvert)** — copier l'URL `SMP racine` directement :

```powershell
curl.exe "https://gis-platform-pre.generix.biz/gnx/phosssmp/iso6523-actorid-upis::0225:391282597_TESTPILOTE"
```

**Harmony / legalRef (token Bearer requis)** — deux étapes :

```powershell
# 1) Récupérer un token
$tok = (curl.exe -s -X POST `
  "https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token" `
  -d "grant_type=client_credentials&client_id=$env:HARMONY_CONNECTOR_CLIENT_ID&client_secret=$env:HARMONY_CONNECTOR_CLIENT_SECRET" `
  | ConvertFrom-Json).access_token

# 2) Appeler l'endpoint
curl.exe -H "Authorization: Bearer $tok" `
  "https://gnx-harmonyconnector-fr-pre.apps.prd.openshift.vmwr/gnx/harmonyconnector-fr/v1/participants/0225:391282597_TESTPILOTE"
```

Pour legalRef : remplacer les variables `HARMONY_CONNECTOR_*` par `LEGALREF_*`
et utiliser l'URL `Ligne annuaire` du rapport.

## Codes de retour

- `0` — exécution terminée (peu importe les KO individuels en mode batch).
- `1` — erreur de config (secret manquant, fichier d'entrée introuvable, aucun
  SIREN valide après nettoyage) ou échec en mode mono-SIREN.
