// core/agents — Agents and image names (594/596/599i): what each agent is called and which accounts it takes.


// ── 596: the image of a new sandbox — Agent × Base ────────────────────────────
// Owner (2026-09-30): "more options in New Sandbox ui page for the base image … recommended base images
// … Dockerfile (requires `container build` which should be installed on-demand) … [COMING SOON] Deck
// Stack Recipes". Two choices (B1): the AGENT (Claude Code · pi · none) and the BASE — Recommended (a
// card per catalogue base), Dockerfile (Choose Dockerfile… is the Mac's own file picker; its folder
// becomes the workspace unless one was set; built with Apple's container build, OUTSIDE Dozer's network
// policy — said on the card) — or a Template (a saved disk).
// The image a pair makes is named as the host names it: claude-code / pi / lab keep their names.
export const AGENTS = [['claude-code', 'Claude Code'], ['pi', 'pi'], ['codex', 'Codex'], ['none', 'none']];
/// B9, the same words as the server's (`Dockerfiles.outsidePolicyNote`).
export const DOCKERFILE_POLICY_NOTE = 'Dockerfile builds run in Apple’s builder (container build), OUTSIDE Dozer’s network policy: its RUN steps reach the internet directly, without Dozer’s proxy or allow list. The sandbox made from the image is under the policy as usual.';
export function imageNameOf(base, agent) {
  if (base === 'node' && agent === 'claude-code') return 'claude-code';
  if (base === 'node' && agent === 'pi') return 'pi';
  if (base === 'node' && agent === 'codex') return 'codex';
  if (base === 'alpine' && agent === 'none') return 'lab';
  return agent === 'none' ? base : base + '-' + agent;
}
export function parseImageName(name, baseIDs) {
  if (name === 'claude-code') return { base: 'node', agent: 'claude-code' };
  if (name === 'pi') return { base: 'node', agent: 'pi' };
  if (name === 'codex') return { base: 'node', agent: 'codex' };
  if (name === 'lab') return { base: 'alpine', agent: 'none' };
  for (const a of ['claude-code', 'pi', 'codex']) if (name.endsWith('-' + a) && baseIDs.includes(name.slice(0, -a.length - 1))) return { base: name.slice(0, -a.length - 1), agent: a };
  return baseIDs.includes(name) ? { base: name, agent: 'none' } : null;
}

// ── 594: an agent's credential prerequisite in a create form ────────────────
// Owner (2026-09-30): "creating a Pi sandbox should have pre-requisites for things like API key so that
// this is not the first experience". The account picker offers only the accounts the chosen image's
// agent can use (the host's table: WebAccounts.agents — pi: an Anthropic API key); an incompatible
// store default is not preselected. When the agent needs one and none fits: "pi needs an Anthropic API
// key", with the masked key field right there (accountForm: the same route and guarantees) — or, with
// ui.allow_secret_entry off, the commands. `ok()` says whether the form may create.
export const AGENT_NAMES = { 'claude-code': 'Claude Code', pi: 'pi', codex: 'Codex' };
export const KIND_LABELS = { mac: 'this Mac’s login', 'setup-token': 'setup token', 'api-key': 'API key', 'openai-key': 'OpenAI API key', chatgpt: 'ChatGPT sign-in',
  'codex-mac': 'this Mac’s Codex login' };
/// 599i: an image name or agent → the agent the accounts table is keyed by (python-codex → codex).
export function agentKey(a, table) {
  if (!a || !table) return a;
  if (table[a]) return a;
  return Object.keys(table).find((k) => a.endsWith('-' + k)) || a;
}
/// 599i: Codex uses OpenAI accounts only (a ChatGPT sign-in or an OpenAI key).
export function isOpenAIAgent(kinds) { return !!kinds && kinds.every((k) => k === 'chatgpt' || k === 'openai-key' || k === 'codex-mac'); }
