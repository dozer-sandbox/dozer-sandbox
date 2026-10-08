// core/hooks — the calls that go UP the layers. A lower module (core, a component) that must call a function a
// higher one owns (a view's render, the router's refresh) names it with upcall('name'); app.js provides every
// such function once, before anything runs. Nothing else goes up: values move down instead.
const provided = Object.create(null);

/// app.js: the functions the lower layers call up into.
export function provide(fns) {
  for (const [name, fn] of Object.entries(fns)) provided[name] = fn;
}

/// A lower module's handle on a function a higher one owns, resolved at each call.
export function upcall(name) {
  return (...args) => provided[name](...args);
}

/// app.js: the names the browser probes use, reachable by name (as the one script's globals were). A provided
/// one is its hook, read and replaced through `provided` — so a probe's wrapper is what the lower layers call.
export function expose(values) {
  for (const [name, value] of Object.entries(values)) {
    if (name in provided) Object.defineProperty(globalThis, name, { get: () => provided[name], set: (fn) => { provided[name] = fn; }, configurable: true });
    else Object.defineProperty(globalThis, name, { value, writable: true, configurable: true });
  }
}
