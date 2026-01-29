#!/usr/bin/env bash
# Listet VM-SKUs <= 2 vCPUs in einer Region, erlaubt Zone-only-Restrictions (portal-nah),
# prüft Quotas und ergänzt Retail-Listenpreise (On-Demand) aus der Azure Retail Prices API.
#
# Preise: https://prices.azure.com/api/retail/prices  (öffentliche Listenpreise)
# Das Skript benötigt: az, jq  (column optional für hübschere Tabellen)

set -euo pipefail

# --- Defaults / CLI-Args ------------------------------------------------------
LOCATION="${LOCATION:-westeurope}"
SUBSCRIPTION=""
SHOW_ALL=0
AS_TABLE=0
CURRENCY="EUR"      # Retail-API currencyCode (z. B. EUR, USD, GBP)
OS_FLAVOR=""        # optionaler OS-Filter für Retail-API: z. B. "Linux", "Windows", "SQL", "RHEL" ...

usage() {
  cat <<EOF
Usage: $(basename "$0") [-l <location>] [-s <subscriptionIdOrName>] [--all] [--table] [--currency <ISO>] [--os <OS>]

  -l, --location       Azure Region (Default: ${LOCATION})
  -s, --subscription   Subscription ID oder Name (optional)
      --all            Zeige ALLE SKUs (auch wenn Quota nicht reicht)
      --table          Ausgabe als Tabelle (ansonsten JSON)
      --currency       Währungscode für Retail-API (Default: EUR)
      --os             OS-Filter für Retail-API (optional: z. B. Linux, Windows)

Beispiele:
  $(basename "$0") -l westeurope --table
  $(basename "$0") -l westeurope --os Windows --table
  $(basename "$0") -l germanywestcentral --all --currency USD --table
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--location) LOCATION="$2"; shift 2;;
    -s|--subscription) SUBSCRIPTION="$2"; shift 2;;
    --all) SHOW_ALL=1; shift;;
    --table) AS_TABLE=1; shift;;
    --currency) CURRENCY="$2"; shift 2;;
    --os) OS_FLAVOR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1;;
  esac
done

# --- Voraussetzungen ----------------------------------------------------------
for cmd in az jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Fehlt: $cmd (bitte installieren)"; exit 1; }
done
if command -v column >/dev/null 2>&1; then
  HAVE_COLUMN=1
else
  HAVE_COLUMN=0
fi

# Optional: Subscription setzen
if [[ -n "$SUBSCRIPTION" ]]; then
  az account set --subscription "$SUBSCRIPTION" >/dev/null
fi

# --- Helper: Preise aus der Azure Retail Prices API holen (robust) ----------
# Parameter:
#   $1 = ARM-Region (z. B. "germanywestcentral")
#   $2 = ARM-SKU    (z. B. "Standard_B2als_v2")
#   $3 = Währung    (Default: "EUR")
#   $4 = (ungenuzt im Server-Filter; historisch: "Consumption")
#   $5 = OS-Filter  (optional: "Windows" | "SQL" | "RHEL" | "SLES"; leer = Linux/AHB-Basis)
# Output:
#   Echo des kleinsten passenden PAYG-Listenpreises pro Stunde (oder "n/a")
fetch_price() {
  local armRegion="$1"
  local armSku="$2"
  local currency="${3:-EUR}"
  local _priceType_unused="${4:-Consumption}"
  local osFilter="${5:-}"

  # API-Basics
  local apiVer="2023-01-01-preview"
  local base_core="https://prices.azure.com/api/retail/prices?api-version=${apiVer}"
  local base_primary="${base_core}&meterRegion=primary"

  # *** WICHTIG ***:
  # Server-seitig NUR minimal filtern (Dienst/Region/ARM-SKU),
  # KEIN 'type eq "Consumption"' im OData-Filter (API-Inkonsistenzen).
  local server_filter="serviceName eq 'Virtual Machines' and armRegionName eq '${armRegion}' and armSkuName eq '${armSku}'"

  # OData-Filter URL-encoden
  local enc_filter
  enc_filter="$(jq -rn --arg f "$server_filter" '$f|@uri')"

  # Pagination-Helper (az rest)
  _fetch_items_pages() {
    local url="$1"
    local next="$url"
    local items="[]"
    while [[ -n "$next" ]]; do
      local resp
      resp="$(az rest --method get --url "$next" 2>/dev/null || true)"
      [[ -z "$resp" ]] && break
      # Items einsammeln
      items="$(jq -n --argjson acc "$items" --argjson add "$(echo "$resp" | jq '.Items')" '$acc + $add')"
      # NextPageLink auswerten
      next="$(echo "$resp" | jq -r '.NextPageLink // empty')"
    done
    echo "$items"
  }

  # 1) Versuch mit meterRegion=primary (reduziert Rauschen; nicht immer gepflegt)
  local url_primary="${base_primary}&currencyCode=${currency}&%24filter=${enc_filter}"
  local items_primary
  items_primary="$(_fetch_items_pages "$url_primary")"

  # 2) Fallback ohne meterRegion (falls primary leer ist)
  local items_all="$items_primary"
  local count_primary
  count_primary="$(echo "$items_primary" | jq 'length')"
  if [[ "$count_primary" -eq 0 ]]; then
    local url_all="${base_core}&currencyCode=${currency}&%24filter=${enc_filter}"
    items_all="$(_fetch_items_pages "$url_all")"
  fi

  # 3) Client-seitige Filter (robust gegen Server-Filter-Quirks):
  #    - Nur Stundenmeter > 0
  #    - echtes PAYG: type == "Consumption"
  #    - Spot/Low Priority ausschließen (tauchen sonst auch als "Consumption" auf)
  #    - "Cloud Services" ausschließen (IaaS-VM-Perspektive)
  #    - OS: bei --os Windows/SQL/RHEL/SLES gezielt aufnehmen; sonst Linux/AHB-Basis
  local items_filtered
  items_filtered="$(
    echo "$items_all" \
    | jq --arg os "$osFilter" '
      [ .[]
        | select((.unitOfMeasure // "") == "1 Hour")
        | select((.retailPrice // 0) > 0)
        | select((.type // "") == "Consumption")
        | select(((.skuName // "")) | contains("Spot") | not)
        | select(((.skuName // "")) | contains("Low Priority") | not)
        | select(((.productName // "")) | contains("Cloud Services") | not)
        | if ($os|length) > 0 then
            # Explizites OS (z. B. Windows/RHEL/SLES/SQL)
            select(((.productName // "")) | contains($os))
          else
            # Linux/AHB-Basis: Windows/SQL/RHEL/SLES ausschließen
            select(((.productName // "")) | contains("Windows") | not)
            | select(((.productName // "")) | contains("SQL") | not)
            | select(((.productName // "")) | contains("RHEL") | not)
            | select(((.productName // "")) | contains("SLES") | not)
          end
      ]'
  )"

  # 4) Kleinsten Retailpreis ermitteln
  local price
  price="$(echo "$items_filtered" | jq -r '[.[].retailPrice] | min // empty')"

  if [[ -n "$price" ]]; then
    echo "$price"
  else
    echo "n/a"
  fi
}

# --- Daten holen --------------------------------------------------------------
# 1) SKUs: <= 2 vCPUs, harte Restrictions raus, Zone-only-Restrictions zulassen (portal-nah)
SKUS_JSON="$(
  az vm list-skus \
    --location "$LOCATION" \
    --resource-type virtualMachines \
    --all \
    --query @- <<'JMES'
[?
  (
    restrictions == null
    || length(restrictions) == `0`
    || length(restrictions[?type!='Zone']) == `0`
  )
  && capabilities[?name=='vCPUs' && to_number(value) <= `2`]
].{
  sku: name,
  family: family,
  vCPUs: to_number(capabilities[?name=='vCPUs']|[0].value)
}
JMES
)"

# 2) Usages/Quotas für die Region
USAGES_JSON="$(az vm list-usage -l "$LOCATION" -o json)"

# --- Auswertung in jq (kompatibel, robust) ------------------------------------
RESULT_JSON="$(
  jq -n \
     --arg location "$LOCATION" \
     --argjson skus "$SKUS_JSON" \
     --argjson usages "$USAGES_JSON" \
     --argjson show_all "$SHOW_ALL" '
  def toNumOrZero: try tonumber catch 0;
  def norm: ascii_downcase | gsub("[^a-z0-9]";"");

  # Usages normalisieren -> Map: normierter Name -> verfügbare vCPUs
  ($usages // []) as $Uraw
  | [ $Uraw[]
      | select(.name.value != null)
      | { k: (.name.value | norm),
          v: (((.limit // 0)|tostring|toNumOrZero) - ((.currentValue // 0)|tostring|toNumOrZero)) }
    ] as $Ulist
  | ( $Ulist
      | map(select(.k != null and .k != "")
            | {key: .k, value: .v})
      | from_entries
    ) as $Umap

  # Total-Avail bestimmen (typisch "cores"; Fallbacks für andere Tenants)
  | (
      $Umap["cores"]
      // $Umap["vcpus"]
      // $Umap["totalregionalvcpus"]
      // $Umap["totalvcpus"]
      // $Umap["standardvcpus"]
      // null
    ) as $TotalAvail

  # Zeilen aufbauen
  | ($skus // []) as $S
  | [ $S[]
      | (.family | norm) as $fkey
      | {
          sku: .sku,
          family: .family,
          vCPUs: .vCPUs,
          familyNormKey: $fkey,
          familyAvail: ($Umap[$fkey] // "n/a"),
          totalAvail: ($TotalAvail // "n/a")
        }
      | .quota_ok = (
          ( ($Umap[$fkey] // null) != null and ($Umap[$fkey] >= .vCPUs) )
          or
          ( ($Umap[$fkey] // null) == null and ($TotalAvail // null) != null and ($TotalAvail >= .vCPUs) )
        )
      | .reason = (
          if .quota_ok then
            if ($Umap[$fkey] // null) == null then
              "OK (Familien-Quota unbekannt, Gesamt-Quota ausreichend)"
            else
              "OK (Familien-Quota ausreichend)"
            end
          else
            if ($Umap[$fkey] // null) == null then
              "NICHT OK (Familien-Quota unbekannt, Gesamt-Quota unzureichend)"
            else
              "NICHT OK (Familien-Quota unzureichend)"
            end
          end
        )
    ] as $rows

  # Ergebnisobjekt + Diagnostikzähler
  | {
      location: $location,
      counts: {
        skus_raw: ($S|length),
        usages_keys: ($Ulist|length),
        family_map_keys: ( [ ($Umap|keys)[] | select(test("family$")) ] | length ),
        total_avail_seen: ($TotalAvail != null)
      },
      items: ( if $show_all == 1 then $rows else [ $rows[] | select(.quota_ok==true) ] end )
    }
  '
)"

# --- Preise injizieren --------------------------------------------------------
ENRICHED_JSON="$(
  items_len="$(echo "$RESULT_JSON" | jq '.items | length')"
  if [[ "$items_len" -eq 0 ]]; then
    echo "$RESULT_JSON"
  else
    echo "$RESULT_JSON" \
    | jq -c --arg loc "$LOCATION" '. as $root | $root.items[] | {sku, family, vCPUs, familyAvail, totalAvail, quota_ok, reason}' \
    | while read -r line; do
        sku="$(echo "$line" | jq -r '.sku')"
        price="$(fetch_price "$LOCATION" "$sku" "$CURRENCY" "Consumption" "$OS_FLAVOR")"
        echo "$line" | jq --arg p "$price" --arg cur "$CURRENCY" '. + {retailPrice: $p, currency: $cur}'
      done \
    | jq -s --argjson header "$RESULT_JSON" '
        {
          location: $header.location,
          counts: $header.counts,
          items: .
        }'
  fi
)"

# --- Ausgabe ------------------------------------------------------------------
if [[ "$AS_TABLE" -eq 1 ]]; then
  if [[ "$HAVE_COLUMN" -eq 1 ]]; then
    echo "$ENRICHED_JSON" \
    | jq -r '
        .items
        | (["SKU","vCPUs","FamAvail","TotAvail","QuotaOK","Price","Currency","Reason"]),
          (.[] | [ .sku, (.vCPUs|tostring), (.familyAvail|tostring), (.totalAvail|tostring), (if .quota_ok then "yes" else "no" end), (.retailPrice|tostring), (.currency // "EUR"), .reason ])
        | @tsv
      ' \
    | column -t -s $'\t'
  else
    echo "$ENRICHED_JSON" \
    | jq -r '
        .items
        | (["SKU","vCPUs","FamAvail","TotAvail","QuotaOK","Price","Currency","Reason"]),
          (.[] | [ .sku, (.vCPUs|tostring), (.familyAvail|tostring), (.totalAvail|tostring), (if .quota_ok then "yes" else "no" end), (.retailPrice|tostring), (.currency // "EUR"), .reason ])
        | @tsv
      '
  fi
else
  echo "$ENRICHED_JSON" | jq .
fi