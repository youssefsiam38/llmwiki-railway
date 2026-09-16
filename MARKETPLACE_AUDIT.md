# Marketplace audit

Checked 2026-09-16.

| Question | Finding |
|---|---|
| Existing Railway templates | None for LLM Wiki, llmwiki or Karpathy's LLM wiki idea (`_audit/gapscan.py`: "llm wiki", "llmwiki", "karpathy"). The closest, "Khoj — Self-Hosted AI Second Brain", is a different product with no deploys. |
| Demand | lucasastorian/llmwiki: about 1,600 stars and 234 forks, 34 commits in the last three months. Karpathy's gist spawned a family of projects; this is the one with a multi-user web app, uploads and an MCP server. |
| Licence | Apache-2.0: redistribution and hosting are allowed. |
| Self-hostable | Yes. The hosted mode needs Supabase (Postgres, Auth with its OAuth 2.1 server) and S3; all run on Railway. Optional external services (Mistral OCR, Cloudflare quiz grading, Voyage, Sentry, Logfire) are not required. |
| Why a template adds value | Upstream documents only its local desktop mode. Hosted mode needs a Supabase Cloud project with the OAuth server and asymmetric JWT keys, an S3 bucket with CORS, the Supabase CLI for migrations, a converter that only accepts Amazon S3, and a web build that bakes in four URLs. Signup is open by default. |
| Not included | The Chrome extension (built with llmwiki.app's addresses). |
