# Azure AI Search — index definitions

Copy-paste index schemas for the Zero-Access Agent's two search indexes. The agent's
only tool is Azure AI Search over these two indexes; it holds no other access.

| File | Index | Holds |
|---|---|---|
| `fleet-structured.index.json` | `fleet-structured` | one document per report row — the "how many / which / where" facts |
| `fleet-docs.index.json` | `fleet-docs` | vector-embedded Intune config documentation — the "how / why" |

> These are **sanitized example schemas** from a personal lab. Adjust the fields to your
> own collector CSVs, and set the `fleet-docs` vectorizer `resourceUri` / `deploymentId`
> to your own Azure OpenAI `text-embedding-3-small` deployment (or embed at indexing time
> and drop the `vectorizers` block).

## Create the indexes

**Portal:** Search service → **Indexes** → **Add index** → *Import from JSON* → paste a file.

**REST (az CLI):**

```bash
SEARCH="https://<your-search-service>.search.windows.net"
KEY="<admin-api-key>"          # use an admin key to CREATE; the agent uses a QUERY key
API="2024-07-01"

for f in fleet-structured.index.json fleet-docs.index.json; do
  curl -sS -X POST "$SEARCH/indexes?api-version=$API" \
    -H "Content-Type: application/json" -H "api-key: $KEY" \
    -d @"$f" | python -m json.tool
done
```

Then create **indexers** that read the sanitized CSV / doc snapshots from Blob Storage
into these indexes on the same schedule the collectors write them.

## Locking it down (the whole point)

- The agent connects with a **query key**, never an admin key — it can search, not modify.
- Restrict the query key with **RBAC / scoped keys** so "don't enumerate people" is enforced
  by access control, not just the system prompt.
- Minimise at the collector first: drop fields a report doesn't need and pre-aggregate the
  sensitive ones (e.g. shadow-AI to counts) *before* they ever reach the index.
