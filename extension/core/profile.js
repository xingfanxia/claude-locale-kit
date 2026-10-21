// Strict v1 profile validator, the JS twin of mac/Sources/ProfileCore/Profile.swift parse().
// Both must agree on profile/fixtures (tests/profile-parity.test.mjs). No dependencies: the
// catalog is passed in so the extension uses generated/catalog.js and tests use scripts/catalog.mjs.

export const SCHEMA_ID = "claude-locale-kit/profile";
export const CURRENT_VERSION = 1;
const TOP_KEYS = new Set(["schema", "version", "timeZone", "locale", "cli"]);
const CLI_KEYS = new Set(["disableTelemetry", "disableErrorReporting"]);

/** `code` matches the Swift ProfileError case; `detail` is the key or value it concerns. */
export class ProfileError extends Error {
  constructor(code, detail = "") {
    super(detail ? `${code}: ${detail}` : code);
    this.name = "ProfileError";
    this.code = code;
    this.detail = detail;
  }
}

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

/** Parses profile JSON text. Throws ProfileError("notJSON") for anything JSON.parse rejects. */
export function parseProfileText(text, catalog) {
  let value;
  try { value = JSON.parse(text); } catch { throw new ProfileError("notJSON"); }
  return parseProfile(value, catalog);
}

/**
 * Validates an already-parsed value and returns a fresh profile object with keys in canonical
 * order. An optional `cli` block is kept as given (only its known keys can exist).
 * @param {{timeZones: Iterable<string>, locales: Iterable<string>}} catalog
 */
export function parseProfile(value, catalog) {
  if (!isObject(value)) throw new ProfileError("notObject");
  for (const key of Object.keys(value)) if (!TOP_KEYS.has(key)) throw new ProfileError("unknownKey", key);

  if (!has(value, "schema")) throw new ProfileError("missingKey", "schema");
  if (typeof value.schema !== "string") throw new ProfileError("wrongType", "schema");
  if (value.schema !== SCHEMA_ID) throw new ProfileError("wrongSchema");

  if (!has(value, "version")) throw new ProfileError("missingKey", "version");
  if (typeof value.version !== "number") throw new ProfileError("wrongType", "version");
  if (value.version !== CURRENT_VERSION) throw new ProfileError("wrongVersion");

  const timeZone = requiredString(value, "timeZone");
  const locale = requiredString(value, "locale");

  let cli;
  if (has(value, "cli")) {
    if (!isObject(value.cli)) throw new ProfileError("wrongType", "cli");
    cli = {};
    for (const key of Object.keys(value.cli)) {
      if (!CLI_KEYS.has(key)) throw new ProfileError("unknownKey", `cli.${key}`);
      if (typeof value.cli[key] !== "boolean") throw new ProfileError("wrongType", `cli.${key}`);
      cli[key] = value.cli[key];
    }
  }

  if (!new Set(catalog.timeZones).has(timeZone)) throw new ProfileError("unknownTimeZone", timeZone);
  if (!new Set(catalog.locales).has(locale)) throw new ProfileError("unknownLocale", locale);

  const profile = { schema: SCHEMA_ID, version: CURRENT_VERSION, timeZone, locale };
  if (cli) profile.cli = cli;
  return profile;
}

function requiredString(obj, key) {
  if (!has(obj, key)) throw new ProfileError("missingKey", key);
  if (typeof obj[key] !== "string") throw new ProfileError("wrongType", key);
  return obj[key];
}

/** Export form: two-space JSON with a trailing newline. */
export const profileJSON = (profile) => JSON.stringify(profile, null, 2) + "\n";
