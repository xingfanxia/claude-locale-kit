// Cases shared by the native and the overridden runs. Each returns a JSON-friendly value; the
// overridden run (host zone A, profile zone B) must produce exactly what a native run in zone B does.
const DAYS = [[2026, 2, 8], [2026, 2, 29], [2026, 3, 5], [2026, 8, 27], [2026, 9, 4], [2026, 9, 25], [2026, 10, 1], [2025, 11, 31]];
const show = (d) => [d.toString(), d.getFullYear(), d.getMonth(), d.getDate(), d.getDay(), d.getHours(), d.getMinutes(),
  d.getSeconds(), d.getTimezoneOffset(), d.toDateString(), d.toTimeString()];

export const cases = {
  instants() {
    const out = [];
    for (const [y, m, d] of DAYS) for (let q = -24; q < 72; q++) out.push(show(new Date(Date.UTC(y, m, d) + q * 1800000)));
    return out;
  },
  wallConstructor() {
    const out = [];
    for (const [y, m, d] of DAYS) for (let h = 0; h < 5; h++) for (const mi of [0, 15, 30, 45]) {
      const x = new Date(y, m, d, h, mi);
      out.push([x.toISOString(), x.getHours(), x.getMinutes()]);
    }
    return out;
  },
  zonelessParse() {
    const texts = ["2026-03-08T02:30:00", "2026-03-08T02:30", "2026-03-29T02:30:00", "2026-03-29T01:30:00",
      "2026-11-01T01:30:00", "2026-10-25T01:30:00", "2026-10-25T02:30:00", "2026-10-04T02:30:00", "2026-04-05T02:30:00",
      "2026-09-27T02:45:00", "2026-03-08T02:30:00.250", "March 8, 2026 02:30:00", "2026/03/08 02:30", "Mar 29 2026 02:30:00",
      "Sun Oct 04 2026 02:30:00", "2026-07-01T12:00:00", "1999-12-31T23:59:59"];
    return texts.map((s) => [s, Date.parse(s), new Date(s).getTime()]);
  },
  zonedParse() {
    return ["2026-03-08T02:30:00Z", "2026-03-08T02:30:00+05:30", "2026-03-08", "2026-03", "Sun Mar 08 2026 02:30:00 GMT-0500",
      "Mar 8 2026 02:30 UTC", "garbage", ""].map((s) => [s, Date.parse(s)]);
  },
  setters() {
    const base = Date.UTC(2026, 2, 7, 12, 30);
    const run = (fn) => { const d = new Date(base); const r = fn(d); return [r, d.getTime()]; };
    return [
      run((d) => d.setDate(8)), run((d) => d.setHours(2, 30)), run((d) => { d.setDate(8); return d.setHours(2, 30); }),
      run((d) => d.setMonth(9, 25)), run((d) => { d.setMonth(9, 25); return d.setHours(1, 30); }),
      run((d) => { d.setMonth(10, 1); return d.setHours(1, 30); }), run((d) => d.setMinutes(-30)), run((d) => d.setSeconds(86400 * 30)),
      run((d) => d.setFullYear(2027)), run((d) => d.setMilliseconds(5)), run((d) => { d.setTime(NaN); return d.setFullYear(2026, 0, 1); }),
      run((d) => { d.setTime(NaN); return d.setHours(1); }),
    ];
  },
  edgeYears() {
    return [new Date(50, 0, 1).getFullYear(), new Date(99, 11, 31, 23).getTime(), new Date(-1, 0).getTime(), new Date(1800, 0, 1).getTime(),
      new Date(Date.UTC(1800, 0, 1)).getTimezoneOffset(), new Date(Date.UTC(-500, 5, 1)).toString(), new Date(8.64e15).toString(),
      new Date(8.64e15 + 1).getTime(), new Date(NaN).toString(), new Date(NaN).getHours()];
  },
  formatting() {
    const t = Date.UTC(2026, 2, 8, 7, 30, 15);
    return [new Date(t).toLocaleString("en-US"), new Date(t).toLocaleDateString("en-GB"), new Date(t).toLocaleTimeString("en-US", { timeZoneName: "short" }),
      new Intl.DateTimeFormat("en-US", { dateStyle: "full", timeStyle: "full" }).format(t), Intl.DateTimeFormat().resolvedOptions().timeZone,
      new Intl.DateTimeFormat("en-US", { timeZone: "Asia/Tokyo", timeStyle: "long" }).format(t), String(new Date(t)), `${new Date(t)}`,
      JSON.stringify(new Date(t)), new Date(t).toISOString(), new Date(t).toUTCString()];
  },
  defaultLocale() {
    const t = Date.UTC(2026, 2, 8, 7, 30, 15);
    return [new Date(t).toLocaleString(), new Date(t).toLocaleDateString(), new Intl.DateTimeFormat().resolvedOptions().locale,
      new Intl.DateTimeFormat([]).resolvedOptions().locale, new Intl.NumberFormat().format(1234567.891), (1234567.891).toLocaleString(),
      (1234567.891).toLocaleString([]), new Intl.NumberFormat([]).resolvedOptions().locale, ["b", "a", "ä"].sort(new Intl.Collator().compare),
      new Intl.PluralRules().select(1), new Intl.RelativeTimeFormat().format(-1, "day"), new Intl.ListFormat().format(["a", "b", "c"]),
      new Date(t).toLocaleString([], { timeStyle: "short" })];
  },
};
