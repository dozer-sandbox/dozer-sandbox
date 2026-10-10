// core/state — The page's one state object (every module shares this one export).


export const state = {
  csrf: null,
  expiresAt: null,
  view: 'overview',
  param: null,
  session: null,           // 593: #/sandbox/NAME/SESSION
  sbx: null,               // 593: the shown sandbox's {name, d, net, accounts}
  opsSeenAt: Date.now(),   // 593: a failure that ended after this is unacknowledged (the Operations badge)
  opsFilter: '',
  imagesMode: 'table',     // 593: Images › Table | Lineage
  overview: null,
  activity: [],
  ops: new Map(),
  es: null,
  renewTimer: null,
  deniedOnly: false,
  signedOut: false,
  metricsFilter: { image: '', days: '', steps: false },
  settings: null,          // 591: {report, byKey} from GET /api/v1/settings
  preps: [],               // 594: the host's image preparations (SSE `preparations`, GET /api/v1/preparations)
  wiz: null,               // 594: the onboarding wizard's state (#/onboarding)
  serve: null,             // 606: doz serve — this browser's facts {exposure, secure, secretsAllowed, mac, device}; null on doz ui
  signup: false,           // this build has the sign-up (an official build): the setup wizard's Stay in touch step
  signupPage: '',          // else: the website's form (from the server — the page names no external URL itself)
  chatgptSignIn: true,     // this build has Dozer's own ChatGPT sign-in (a public build: false — never offered)
};
