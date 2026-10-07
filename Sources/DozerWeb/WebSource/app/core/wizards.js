// core/wizards — The onboarding wizard's steps (594, 599g).


// ── onboarding (594) ────────────────────────────────────────────────────────
// The wizard (D11): Welcome → Checks → Access → Workspace rules (599g) → Images → Preparing → First sandbox → Done.
// The same model as every page: facts from GET /api/v1/onboarding; changes through the typed actions
// (account-default, onboard, prepare-cancel, create) and ONE typed route for the settings file and
// the prompt template (POST /api/v1/onboarding/config — each written only when missing, never
// overwritten). A key or a setup token: the masked field (accountForm) while ui.allow_secret_entry,
// else the CLI command. The preparation runs in the HOST: "Continue in the background" leaves it
// running (Operations shows it), and closing this tab changes nothing.
export const WIZ_STEPS = ['Welcome', 'Checks', 'Access', 'Workspace rules', 'Images', 'Preparing', 'First sandbox', 'Done'];
// The steps by name (599g put Workspace rules between Access and Images).
export const WIZ = { welcome: 0, checks: 1, access: 2, rules: 3, images: 4, preparing: 5, first: 6, done: 7 };
export const WIZ_ORDER = ['claude-code', 'pi', 'codex', 'lab'];
