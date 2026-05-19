# ligne-adressage-check

Vérifie l'enregistrement d'un participant (par son SIREN) sur trois systèmes :

1. **Peppol** — résolution SML/SMP et récupération des informations d'Access Point.
2. **Harmony-connector** — contrôle que le routage du participant est en place.
3. **legalRef** — récupération de la ligne d'annuaire associée au SIREN.

Le script déduit automatiquement l'environnement (`uat`, `pre`, `prd`) et le PA
(`gnx`, `fulll`, `pitney-bowes`, `pytheas`, …) à partir des informations Peppol.

## Contenu du dépôt

| Fichier                 | Description                                                        |
|-------------------------|--------------------------------------------------------------------|
| `ligne_full_check.ps1`  | Version Windows / PowerShell (aucune dépendance externe).          |
| `ligne_full_check.sh`   | Version Bash / Linux (requiert `curl`, `jq`, `base32`, `xmllint`, `openssl`, `dig`). |
| `run.cmd`               | Lanceur Windows interactif pour le script PowerShell.              |
| `script.env.example`    | Modèle de configuration des secrets.                               |

## Configuration

Les scripts ont besoin de quatre secrets. Copiez le modèle et renseignez vos valeurs :

```sh
cp script.env.example script.env
```

`script.env` est ignoré par git et ne doit **jamais** être committé.

## Utilisation

### Windows (PowerShell)

Double-cliquez sur `run.cmd`, ou en ligne de commande :

```bat
run.cmd 432526903_TESTPILOTE
run.cmd 432526903_TESTPILOTE false   :: mode ERROR_ONLY
```

Ou directement :

```powershell
.\ligne_full_check.ps1 432526903_TESTPILOTE
```

### Linux / macOS (Bash)

```sh
. ./script.env
./ligne_full_check.sh 432526903_TESTPILOTE
./ligne_full_check.sh 432526903_TESTPILOTE false   # mode ERROR_ONLY
```

Le second argument contrôle le mode d'affichage :

- `true` (défaut) — mode DEBUG, affiche toutes les informations ;
- `false` — mode ERROR_ONLY, n'affiche que les erreurs.
