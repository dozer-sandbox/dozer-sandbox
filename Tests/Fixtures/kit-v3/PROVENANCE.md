# Docker Sandbox Kit v3 — vendored JSON Schemas (test fixture)

These files are copied unchanged from Docker's Sandbox Kit specification repository, for one test only
(`RecipeSchemaTests.testTheKitViewOfEveryRecipeIsAValidKitV3Descriptor`): it builds the Kit-shaped view of every
Dozer recipe in memory and validates it against Kit's own published schema, so a drift between Dozer's recipe
format and Kit v3 shows up as a failing test.

- Source: https://github.com/docker/sandbox-kit-spec (directory `schema/`)
- Commit: `d536fc04bea406d41ed3649d5c785b3176f02741` (2026-10-11)
- Licence: Apache-2.0 — `LICENSE` here is the repository's own, unchanged.
- Files: `kit.schema.json`, `definitions/kit-arg.schema.json`, and the capability schemas Dozer recipes use
  (`capabilities/com.docker.sandbox/{network-policy,credential,lifecycle,agent-context,volume}@1.schema.json`).
  `kit.schema.json` names other capability schemas; they are resolved only for a capability of that type, which no
  Dozer recipe has.

The specification is experimental (final version due Q4 2026). To move to a newer commit, copy the same files from
it, update the commit above, and run `RecipeSchemaTests`.
