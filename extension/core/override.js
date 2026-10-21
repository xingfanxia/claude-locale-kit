// Runs in the page's MAIN world at document_start, after one tz preset and one locale preset
// script have set self.__claudeLocaleKit synchronously. No async work, so page scripts can never
// run before the override is in place in the frames Chrome injects into.
//
// Scope, stated plainly: this changes what JavaScript in claude.ai frames reads for the time zone
// and language. It does not hide that it is an override (Function.prototype.toString and other
// probes can tell), and it does not reach Web Workers, the network address, or the account.
(() => {
  "use strict";
  const cfg = self.__claudeLocaleKit;
  try { delete self.__claudeLocaleKit; } catch { /* non-configurable in some frames */ }
  if (!cfg || typeof cfg.timeZone !== "string" || typeof cfg.locale !== "string" || !Array.isArray(cfg.languages)) return;
  if (self.__claudeLocaleKitActive) return;
  Object.defineProperty(self, "__claudeLocaleKitActive", { value: true });

  const TZ = cfg.timeZone;
  const LOCALE = cfg.locale;
  const LANGUAGES = Object.freeze(cfg.languages.slice());

  const NativeDate = Date;
  const DP = NativeDate.prototype;
  const NativeDTF = Intl.DateTimeFormat;
  const apply = Reflect.apply;
  const nat = {};
  for (const k of ["getTime", "setTime", "getUTCFullYear", "getUTCMonth", "getUTCDate", "getUTCDay", "getUTCHours",
    "getUTCMinutes", "getUTCSeconds", "getUTCMilliseconds", "setUTCFullYear", "setUTCMonth", "setUTCDate",
    "setUTCHours", "setUTCMinutes", "setUTCSeconds", "setUTCMilliseconds", "setFullYear", "setHours", "getTimezoneOffset", "toLocaleString",
    "toLocaleDateString", "toLocaleTimeString"]) nat[k] = DP[k];
  const time = (d) => apply(nat.getTime, d, []);
  const MAX = 8.64e15;
  const clip = (t) => (Number.isFinite(t) && Math.abs(t) <= MAX ? Math.trunc(t) + 0 : NaN);

  // ---- offset math -------------------------------------------------------------------------
  const partsFmt = new NativeDTF("en-US", {
    timeZone: TZ, hourCycle: "h23", era: "short",
    year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
  });
  const scratch = new NativeDate(0);
  const utcFromFields = (y, mo, d, h, mi, s, ms) => {
    apply(nat.setTime, scratch, [0]);
    apply(nat.setUTCFullYear, scratch, [y, mo, d]);
    apply(nat.setUTCHours, scratch, [h, mi, s, ms]);
    return time(scratch);
  };
  const CYCLE = 146097 * 86400000; // 400 Gregorian years; weekdays repeat too
  const offsetCache = new Map();
  /** Offset in ms (local = utc + offset) of TZ at instant t. */
  function offsetAt(t) {
    const key = Math.floor(t / 60000);
    let o = offsetCache.get(key);
    if (o !== undefined) return o;
    const f = {};
    for (const p of partsFmt.formatToParts(t)) f[p.type] = p.value;
    let y = Number(f.year);
    if (f.era === "BC" || f.era === "B") y = 1 - y;
    const ms = ((t % 1000) + 1000) % 1000;
    // Near the ends of the Date range the wall clock itself may be out of range: build it 400 years inward.
    const k = t > MAX / 2 ? -1 : t < -MAX / 2 ? 1 : 0;
    o = utcFromFields(y + k * 400, Number(f.month) - 1, Number(f.day), Number(f.hour), Number(f.minute), Number(f.second), ms) - k * CYCLE - t;
    if (offsetCache.size > 4096) offsetCache.clear();
    offsetCache.set(key, o);
    return o;
  }
  /** Wall-clock ms (as if UTC) -> instant, following ECMA-262: earlier instant for repeated
   * times, and the pre-transition offset for skipped times. */
  function wallToUtc(w) {
    if (!Number.isFinite(w)) return NaN;
    const before = offsetAt(Math.max(w - 86400000, -MAX));
    const after = offsetAt(Math.min(w + 86400000, MAX));
    let best = NaN;
    for (const o of before === after ? [before] : [before, after]) {
      const t = w - o;
      if (offsetAt(t) === o && !(t >= best)) best = t;
    }
    return Number.isNaN(best) ? w - before : best;
  }
  const wallOf = (t) => t + offsetAt(t);

  // ---- Date --------------------------------------------------------------------------------
  const ISO_DATE_ONLY = /^[+-]?\d{4,6}(-\d\d(-\d\d)?)?$/;
  const HAS_ZONE = /(?:Z|[+-]\d\d(?::?\d\d)?|\b(?:GMT|UTC|UT|[ECMP][SD]T)\b[+-]?\d*(?::?\d\d)?)\s*(?:\([^)]*\))?\s*$/i;
  const nativeParse = NativeDate.parse;
  /** Instant the browser's own zone assigns to wall-clock w (native local constructor). */
  function hostInstant(w) {
    const d = new NativeDate(0);
    apply(nat.setTime, scratch, [w]);
    apply(nat.setFullYear, d, [apply(nat.getUTCFullYear, scratch, []), apply(nat.getUTCMonth, scratch, []), apply(nat.getUTCDate, scratch, [])]);
    apply(nat.setHours, d, [apply(nat.getUTCHours, scratch, []), apply(nat.getUTCMinutes, scratch, []), apply(nat.getUTCSeconds, scratch, []), apply(nat.getUTCMilliseconds, scratch, [])]);
    return time(d);
  }
  function parse(str) {
    const s = String(str);
    const t = nativeParse(s);
    if (Number.isNaN(t) || ISO_DATE_ONLY.test(s.trim()) || HAS_ZONE.test(s.trim())) return t;
    // The engine read a zone-less string as browser-local time; recover the written wall clock
    // and reread it in TZ. Reading it back from t alone fails inside a browser-zone DST gap
    // (02:30 has already become 03:30), so first reparse the text as UTC and keep that wall
    // clock when the browser zone maps it to the same instant.
    for (const suffix of ["Z", " GMT"]) {
      const w = nativeParse(s + suffix);
      if (!Number.isNaN(w) && hostInstant(w) === t) return wallToUtc(w);
    }
    const nativeWall = t - apply(nat.getTimezoneOffset, new NativeDate(t), []) * 60000;
    return wallToUtc(nativeWall);
  }
  function toPrimitive(v) {
    if (v === null || (typeof v !== "object" && typeof v !== "function")) return v;
    const exotic = v[Symbol.toPrimitive];
    if (exotic != null) return apply(exotic, v, ["default"]);
    for (const m of ["valueOf", "toString"]) {
      const fn = v[m];
      if (typeof fn === "function") { const r = apply(fn, v, []); if (r === null || (typeof r !== "object" && typeof r !== "function")) return r; }
    }
    throw new TypeError("Cannot convert object to primitive value");
  }
  function dateValueOf(v) {
    try { return time(v); } catch { return undefined; }
  }

  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const pad = (n, w = 2) => String(n).padStart(w, "0");
  const nameFmt = new NativeDTF(LOCALE, { timeZone: TZ, timeZoneName: "long" });
  // Like V8, name instants outside 1970..2038 after an equivalent year (same leap-ness and
  // weekday of 1 January, within 2008..2035), so historic and far-future dates get the zone's
  // standard/daylight name rather than an ICU "GMT-04:56:02" fallback.
  const DAY = 86400000;
  function equivalentTime(t) {
    apply(nat.setTime, scratch, [t]);
    const y = apply(nat.getUTCFullYear, scratch, []);
    const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
    const jan1 = new NativeDate(0);
    apply(nat.setUTCFullYear, jan1, [y, 0, 1]);
    const weekDay = apply(nat.getUTCDay, jan1, []);
    const recent = (leap ? 1956 : 1967) + ((weekDay * 12) % 28);
    const within = ((t % DAY) + DAY) % DAY;
    const days = Math.floor(t / DAY) - Math.floor(time(jan1) / DAY);
    return utcFromFields(2008 + ((recent + 3 * 28 - 2008) % 28), 0, 1, 0, 0, 0, 0) + days * DAY + within;
  }
  function zoneName(t) {
    const at = t < 0 || t > 2147483647000 ? equivalentTime(t) : t;
    const p = nameFmt.formatToParts(at).find((x) => x.type === "timeZoneName");
    return p ? p.value : TZ;
  }
  function fields(t) {
    // Near ±8.64e15 the wall clock can fall outside the Date range; shift by 400 years to read it.
    const w = wallOf(t);
    const shift = w > MAX ? -1 : w < -MAX ? 1 : 0;
    apply(nat.setTime, scratch, [w + shift * CYCLE]);
    return {
      y: apply(nat.getUTCFullYear, scratch, []) - shift * 400, mo: apply(nat.getUTCMonth, scratch, []), d: apply(nat.getUTCDate, scratch, []),
      wd: apply(nat.getUTCDay, scratch, []), h: apply(nat.getUTCHours, scratch, []), mi: apply(nat.getUTCMinutes, scratch, []),
      s: apply(nat.getUTCSeconds, scratch, []),
    };
  }
  const yearStr = (y) => (y < 0 ? "-" : "") + pad(Math.abs(y), 4);
  function datePart(t) { const f = fields(t); return `${DAYS[f.wd]} ${MONTHS[f.mo]} ${pad(f.d)} ${yearStr(f.y)}`; }
  function timePart(t) {
    const f = fields(t);
    const o = Math.trunc(offsetAt(t) / 60000);
    const sign = o >= 0 ? "+" : "-";
    const a = Math.abs(o);
    return `${pad(f.h)}:${pad(f.mi)}:${pad(f.s)} GMT${sign}${pad(Math.floor(a / 60))}${pad(a % 60)} (${zoneName(t)})`;
  }

  function FakeDate(...args) {
    if (!new.target) return `${datePart(NativeDate.now())} ${timePart(NativeDate.now())}`;
    let t;
    if (args.length === 0) t = NativeDate.now();
    else if (args.length === 1) {
      const dv = dateValueOf(args[0]);
      if (dv !== undefined) t = dv;
      else { const p = toPrimitive(args[0]); t = typeof p === "string" ? parse(p) : clip(Number(p)); }
    } else {
      const n = args.slice(0, 7).map(Number);
      let [y, mo, d = 1, h = 0, mi = 0, s = 0, ms = 0] = n;
      if (Number.isFinite(y)) { const yi = Math.trunc(y); if (yi >= 0 && yi <= 99) y = 1900 + yi; }
      t = n.every(Number.isFinite) && [d, h, mi, s, ms].every(Number.isFinite)
        ? clip(wallToUtc(utcFromFields(y, mo, d, h, mi, s, ms))) : NaN;
    }
    return Reflect.construct(NativeDate, [t], new.target);
  }
  Object.defineProperty(FakeDate, "length", { value: 7 });
  Object.defineProperty(FakeDate, "name", { value: "Date" });
  Object.defineProperty(FakeDate, "prototype", { value: DP });
  for (const k of ["now", "UTC"]) Object.defineProperty(FakeDate, k, { value: NativeDate[k], writable: true, configurable: true });
  Object.defineProperty(FakeDate, "parse", { value: function parse_(s) { return parse(s); }, writable: true, configurable: true });
  Object.defineProperty(FakeDate.parse, "name", { value: "parse" });
  Object.defineProperty(DP, "constructor", { value: FakeDate, writable: true, configurable: true });

  const define = (obj, name, fn) => {
    Object.defineProperty(fn, "name", { value: name });
    Object.defineProperty(obj, name, { value: fn, writable: true, configurable: true, enumerable: false });
  };
  const getter = (name, pick) => define(DP, name, function () {
    const t = time(this);
    return Number.isNaN(t) ? NaN : pick(fields(t));
  });
  getter("getFullYear", (f) => f.y);
  getter("getMonth", (f) => f.mo);
  getter("getDate", (f) => f.d);
  getter("getDay", (f) => f.wd);
  getter("getHours", (f) => f.h);
  getter("getMinutes", (f) => f.mi);
  getter("getSeconds", (f) => f.s);
  if (typeof DP.getYear === "function") getter("getYear", (f) => f.y - 1900);
  define(DP, "getMilliseconds", function () { return apply(nat.getUTCMilliseconds, this, []); });
  define(DP, "getTimezoneOffset", function () {
    const t = time(this);
    return Number.isNaN(t) ? NaN : 0 - Math.trunc(offsetAt(t) / 60000); // V8 truncates to whole minutes
  });

  // Local setters: move to wall time, apply the UTC setter there, move back.
  const setter = (name, utcName, nanStartsAtZero = false) => define(DP, name, function (...a) {
    let t = time(this);
    if (Number.isNaN(t)) { if (!nanStartsAtZero) { a.forEach(Number); return NaN; } t = 0; }
    const w = new NativeDate(nanStartsAtZero && Number.isNaN(time(this)) ? 0 : wallOf(t));
    apply(nat[utcName], w, a);
    const r = clip(wallToUtc(time(w)));
    apply(nat.setTime, this, [r]);
    return r;
  });
  setter("setFullYear", "setUTCFullYear", true);
  setter("setMonth", "setUTCMonth");
  setter("setDate", "setUTCDate");
  setter("setHours", "setUTCHours");
  setter("setMinutes", "setUTCMinutes");
  setter("setSeconds", "setUTCSeconds");
  setter("setMilliseconds", "setUTCMilliseconds");
  if (typeof DP.setYear === "function") define(DP, "setYear", function (y) {
    let yy = Number(y);
    if (Number.isNaN(yy)) { apply(nat.setTime, this, [NaN]); return NaN; }
    yy = Math.trunc(yy);
    if (yy >= 0 && yy <= 99) yy += 1900;
    return DP.setFullYear.call(this, yy);
  });

  const str = (name, render) => define(DP, name, function () {
    const t = time(this);
    return Number.isNaN(t) ? "Invalid Date" : render(t);
  });
  str("toString", (t) => `${datePart(t)} ${timePart(t)}`);
  str("toDateString", datePart);
  str("toTimeString", timePart);

  const withZone = (options) => {
    if (options === undefined) return { timeZone: TZ };
    if (options === null) return options; // let the engine throw as it would natively
    const o = Object(options);
    return o.timeZone === undefined ? Object.create(o, { timeZone: { value: TZ, enumerable: true } }) : o;
  };
  // An empty locale list also means "the default locale" to the engine.
  const loc = (locales) => (locales === undefined || (Array.isArray(locales) && locales.length === 0) ? LOCALE : locales);
  for (const k of ["toLocaleString", "toLocaleDateString", "toLocaleTimeString"]) {
    define(DP, k, function (locales, options) { return apply(nat[k], this, [loc(locales), withZone(options)]); });
  }

  self.Date = FakeDate;

  // ---- Intl --------------------------------------------------------------------------------
  function wrapIntl(name, mapOptions) {
    const Native = Intl[name];
    if (typeof Native !== "function") return;
    const callable = name === "DateTimeFormat" || name === "NumberFormat" || name === "Collator";
    function Wrapped(locales, options) {
      if (!new.target && !callable) throw new TypeError(`Constructor Intl.${name} requires 'new'`);
      const args = [loc(locales), mapOptions ? mapOptions(options) : options];
      if (!mapOptions && options === undefined) args.length = 1;
      return Reflect.construct(Native, args, new.target || Native);
    }
    Object.defineProperty(Wrapped, "name", { value: name });
    Object.defineProperty(Wrapped, "length", { value: 0 });
    Object.defineProperty(Wrapped, "prototype", { value: Native.prototype });
    Object.defineProperty(Wrapped, "supportedLocalesOf", { value: Native.supportedLocalesOf, writable: true, configurable: true });
    Object.defineProperty(Native.prototype, "constructor", { value: Wrapped, writable: true, configurable: true });
    Object.defineProperty(Intl, name, { value: Wrapped, writable: true, configurable: true });
  }
  wrapIntl("DateTimeFormat", withZone);
  for (const n of ["NumberFormat", "Collator", "PluralRules", "RelativeTimeFormat", "ListFormat", "Segmenter", "DurationFormat"]) wrapIntl(n);
  if (typeof Intl.DisplayNames === "function") {
    const NativeDN = Intl.DisplayNames;
    function DisplayNames(locales, options) {
      if (!new.target) throw new TypeError("Constructor Intl.DisplayNames requires 'new'");
      return Reflect.construct(NativeDN, [loc(locales), options], new.target);
    }
    Object.defineProperty(DisplayNames, "prototype", { value: NativeDN.prototype });
    Object.defineProperty(DisplayNames, "length", { value: 2 });
    Object.defineProperty(DisplayNames, "supportedLocalesOf", { value: NativeDN.supportedLocalesOf, writable: true, configurable: true });
    Object.defineProperty(NativeDN.prototype, "constructor", { value: DisplayNames, writable: true, configurable: true });
    Object.defineProperty(Intl, "DisplayNames", { value: DisplayNames, writable: true, configurable: true });
  }

  const localeMethod = (proto, name) => {
    const native = proto && proto[name];
    if (typeof native !== "function") return;
    define(proto, name, function (locales, ...rest) { return apply(native, this, [loc(locales), ...rest]); });
  };
  localeMethod(Number.prototype, "toLocaleString");
  localeMethod(typeof BigInt === "function" ? BigInt.prototype : null, "toLocaleString");
  localeMethod(String.prototype, "toLocaleUpperCase");
  localeMethod(String.prototype, "toLocaleLowerCase");
  {
    const native = String.prototype.localeCompare;
    define(String.prototype, "localeCompare", function (that, locales, options) {
      return apply(native, this, [that, loc(locales), options]);
    });
  }

  // ---- Temporal (only if this Chrome ships it) ----------------------------------------------
  const T = self.Temporal;
  if (T && T.Now) {
    const N = T.Now;
    define(N, "timeZoneId", function () { return TZ; });
    for (const k of ["zonedDateTimeISO", "plainDateTimeISO", "plainDateISO", "plainTimeISO"]) {
      const native = N[k];
      if (typeof native === "function") define(N, k, function (tz) { return apply(native, N, [tz === undefined ? TZ : tz]); });
    }
  }

  // ---- navigator.language(s) ----------------------------------------------------------------
  const NavProto = self.Navigator && self.Navigator.prototype;
  if (NavProto) {
    Object.defineProperty(NavProto, "language", { get: function language() { return LANGUAGES[0]; }, configurable: true, enumerable: true });
    Object.defineProperty(NavProto, "languages", { get: function languages() { return LANGUAGES; }, configurable: true, enumerable: true });
  }
})();
