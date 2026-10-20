// Pure helpers shared by admin and student pages (no network, testable in node).

export const SUBJECTS = ['physics', 'chemistry', 'mathematics', 'biology'];
// key: [name, what she does, timing]
export const STRATEGIES = {
  subject: ['Subject by subject', 'One subject at a time. No going back.', 'Alerts every 30 min'],
  timebox: ['Time-boxed subjects', 'Equal time per subject, then 20 min to return to marked questions.', '100 min split + 20 min'],
  three_round: ['Three-round sweep', 'Easy questions first across the paper, then moderate, then hard.', '50 + 45 + 25 min'],
  two_pass: ['Strongest first + two-pass', 'You pick the subject order. Skip and mark in pass 1, return in pass 2.', '80 + 40 min'],
  free: ['Free mode', 'No guidance. The plain exam and the total timer.', 'Total timer only'],
};
export const stratName = (k) => STRATEGIES[k]?.[0] ?? k;

export const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Escape first, then turn sqrt(x), x^2, x^{-3}, H_2O into readable markup.
export const fmt = (s) =>
  esc(s)
    .replace(/sqrt\(([^()]*)\)/g, '√($1)')
    .replace(/\^\{([^}]+)\}|\^(-?\w)/g, (_, a, b) => `<sup>${a ?? b}</sup>`)
    .replace(/_\{([^}]+)\}|_(\w)/g, (_, a, b) => `<sub>${a ?? b}</sub>`)
    .replace(/\n/g, '<br>');

// Minimal RFC-4180 CSV parser: quoted fields, "" escapes, newlines inside quotes.
export function parseCSV(t) {
  const rows = [];
  let r = [], c = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (q) {
      if (ch === '"') { if (t[i + 1] === '"') { c += '"'; i++; } else q = false; }
      else c += ch;
    } else if (ch === '"') q = true;
    else if (ch === ',') { r.push(c); c = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && t[i + 1] === '\n') i++;
      r.push(c); c = ''; rows.push(r); r = [];
    } else c += ch;
  }
  if (c || r.length) { r.push(c); rows.push(r); }
  return rows.filter((x) => x.some((v) => v.trim()));
}

export const CSV_HEADER = 'subject,chapter,question,option_a,option_b,option_c,option_d,correct,solution,marks';

export const cap = (s) => s[0].toUpperCase() + s.slice(1);
export const when = (d) => new Date(d).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
// Stat tile; the result hero passes cls '' to drop the card frame
export const stat = (k, v, sub = '', cls = 'card') => `<div class="${cls} stat"><span class="lbl">${k}</span><span class="v">${v} <span class="u">${sub}</span></span></div>`;

// Which stage of a strategy the clock is in. Stage lengths are written for a 120-minute paper
// and scale if the test has a different duration. Timebox splits 100 min across the subjects in the test.
export function phaseOf(strategy, elapsedMs, durationMs, order = SUBJECTS) {
  const m = (Math.max(0, Math.min(elapsedMs, durationMs)) / durationMs) * 120;
  const toMs = (min) => (min / 120) * durationMs;
  const stage = (cuts, labels, lock) => {
    let i = cuts.findIndex((c) => m < c);
    if (i < 0) i = cuts.length - 1;
    return { idx: i, label: labels[i], lock: lock ? lock(i) : null, endsInMs: toMs(cuts[i]) - elapsedMs, final: i === cuts.length - 1 };
  };
  if (strategy === 'timebox')
    return stage([...order.map((_, i) => ((i + 1) * 100) / order.length), 120], [...order.map((s) => `${cap(s)} box`), 'Review marked and skipped'], (i) => order[i] ?? null);
  if (strategy === 'three_round')
    return stage([50, 95, 120], ['Round 1: easy questions', 'Round 2: moderate questions', 'Round 3: hard questions and review']);
  if (strategy === 'two_pass') return stage([80, 120], ['Pass 1: answer, skip, mark', 'Pass 2: skipped and marked']);
  if (strategy === 'subject') {
    const idx = Math.min(3, Math.floor(m / 30));
    return { idx, label: idx ? `${idx * 30} min used` : 'Subject by subject', lock: null, endsInMs: Infinity, final: true };
  }
  return { idx: 0, label: 'Free mode', lock: null, endsInMs: Infinity, final: true };
}

// Rows -> { ok: [question objects], errors: ['Row 3: ...'] }
export function readQuestions(csvText) {
  const rows = parseCSV(csvText.replace(/^﻿/, ''));
  if (!rows.length) return { ok: [], errors: ['File is empty'] };
  const head = rows[0].map((h) => h.trim().toLowerCase());
  const col = (name) => head.indexOf(name);
  const need = ['subject', 'question', 'option_a', 'option_b', 'option_c', 'option_d', 'correct'];
  const missing = need.filter((n) => col(n) < 0);
  if (missing.length) return { ok: [], errors: ['Missing columns: ' + missing.join(', ')] };
  const ok = [], errors = [];
  rows.slice(1).forEach((r, i) => {
    const g = (n) => (col(n) < 0 ? '' : (r[col(n)] ?? '').trim());
    const line = i + 2;
    const subj = SUBJECTS.find((s) => s.startsWith(g('subject').toLowerCase().slice(0, 3)) && g('subject').length >= 3);
    const options = ['a', 'b', 'c', 'd'].map((x) => g('option_' + x));
    const k = g('correct').toUpperCase();
    const correct = 'ABCD'.includes(k) && k.length === 1 ? 'ABCD'.indexOf(k) : Number(k) >= 1 && Number(k) <= 4 ? Number(k) - 1 : -1;
    const marks = g('marks') ? Number(g('marks')) : 4;
    if (!subj) errors.push(`Row ${line}: unknown subject "${g('subject')}"`);
    else if (!g('question')) errors.push(`Row ${line}: empty question`);
    else if (options.some((o) => !o)) errors.push(`Row ${line}: all 4 options are needed`);
    else if (correct < 0) errors.push(`Row ${line}: correct must be A, B, C or D`);
    else if (!Number.isFinite(marks) || marks <= 0) errors.push(`Row ${line}: bad marks`);
    else ok.push({ subject: subj, chapter: g('chapter'), body: g('question'), options, marks, correct, solution: g('solution') });
  });
  return { ok, errors };
}

/* ---------- analytics (used by student Progress and admin Report) ---------- */

export const verdictOf = (chosen, correct) => (chosen == null ? 'S' : chosen === correct ? 'C' : 'W');
export const pct = (a) => (a.max ? Math.round((a.score / a.max) * 100) : 0);

// Per chapter, weakest first. Skipped counts as not right.
export function chapterStats(rows, minTotal = 2) {
  const m = new Map();
  for (const r of rows) {
    const chapter = r.chapter || 'No chapter', k = r.subject + '|' + chapter;
    const e = m.get(k) ?? { subject: r.subject, chapter, right: 0, wrong: 0, skipped: 0, total: 0 };
    const v = verdictOf(r.chosen, r.correct);
    e.total++;
    if (v === 'C') e.right++; else if (v === 'W') e.wrong++; else e.skipped++;
    m.set(k, e);
  }
  return [...m.values()].filter((e) => e.total >= minTotal).map((e) => ({ ...e, acc: e.right / e.total }))
    .sort((a, b) => a.acc - b.acc || b.total - a.total);
}

// Average score % per attempt strategy
export function strategyStats(attempts) {
  const m = {};
  for (const a of attempts) {
    const e = (m[a.strategy] ??= { strategy: a.strategy, n: 0, sum: 0, best: 0 });
    e.n++; e.sum += pct(a); e.best = Math.max(e.best, pct(a));
  }
  return Object.values(m).map((e) => ({ strategy: e.strategy, n: e.n, avg: Math.round(e.sum / e.n), best: e.best })).sort((a, b) => b.avg - a.avg);
}

// Per subject: right/wrong/skipped, accuracy on attempted, seconds spent
export function subjectStats(rows, attempts) {
  const times = new Map(attempts.map((a) => [a.id, a.times || {}]));
  return SUBJECTS.map((s) => {
    const l = rows.filter((r) => r.subject === s);
    const c = l.filter((r) => verdictOf(r.chosen, r.correct) === 'C').length;
    const w = l.filter((r) => verdictOf(r.chosen, r.correct) === 'W').length;
    const secs = l.reduce((x, r) => x + (times.get(r.attempt_id)?.[r.question_id] || 0), 0);
    return { subject: s, total: l.length, right: c, wrong: w, skipped: l.length - c - w, acc: c + w ? Math.round((c / (c + w)) * 100) : null, secs, perQ: l.length ? Math.round(secs / l.length) : 0 };
  });
}

// Questions whose latest result is not correct, minus ones she re-did correctly in practice since then.
// cleared: { questionId: msTimestamp }
export function mistakes(rows, cleared = {}) {
  const last = new Map();
  for (const r of rows) {
    const p = last.get(r.question_id);
    if (!p || r.submitted_at > p.submitted_at) last.set(r.question_id, r);
  }
  return [...last.values()].filter((r) => verdictOf(r.chosen, r.correct) !== 'C' && !(cleared[r.question_id] > Date.parse(r.submitted_at)));
}

// Weekly (or any period) report data
export function periodReport(attempts, rows, sinceMs) {
  const at = attempts.filter((a) => Date.parse(a.submitted_at) >= sinceMs);
  const ids = new Set(at.map((a) => a.id));
  const pr = rows.filter((r) => ids.has(r.attempt_id));
  const flags = { fullscreen_exit: 0, tab_hidden: 0 };
  at.forEach((a) => (a.flags || []).forEach((f) => { if (f.type in flags) flags[f.type]++; }));
  const subs = subjectStats(pr, at).filter((s) => s.total);
  const pcts = at.map(pct);
  return {
    attempts: at, tests: at.length, avg: at.length ? Math.round(pcts.reduce((x, y) => x + y, 0) / at.length) : null,
    best: at.length ? Math.max(...pcts) : null, flags, subjects: subs,
    strongest: [...subs].filter((s) => s.acc != null).sort((a, b) => b.acc - a.acc)[0] ?? null,
    weakest: [...subs].filter((s) => s.acc != null).sort((a, b) => a.acc - b.acc)[0] ?? null,
    weak: chapterStats(pr, 2).slice(0, 5), strategies: strategyStats(at),
  };
}

// Small line chart as an SVG string. points: [{ label, value }] with value 0-100. Styled by .trend in style.css.
export function trendSvg(points) {
  const w = 560, h = 150;
  if (points.length < 2) return `<p class="muted">The trend appears after 2 tests.${points.length ? ` So far: ${points[0].value}%.` : ''}</p>`;
  const L = 24, R = 24, T = 22, B = 28, x = (i) => L + (i * (w - L - R)) / (points.length - 1), y = (v) => T + ((100 - v) / 100) * (h - T - B);
  return `<svg class="trend" viewBox="0 0 ${w} ${h}" role="img" aria-label="Score trend: ${esc(points.map((p) => `${p.label} ${p.value}%`).join(', '))}">
    <line class="axis" x1="${L}" y1="${y(0)}" x2="${w - R}" y2="${y(0)}"/>
    <polyline class="line" points="${points.map((p, i) => `${x(i)},${y(p.value)}`).join(' ')}"/>
    ${points.map((p, i) => `<circle cx="${x(i)}" cy="${y(p.value)}" r="5"/><text class="val" x="${x(i)}" y="${y(p.value) - 10}" text-anchor="middle">${p.value}%</text><text class="x" x="${x(i)}" y="${h - 8}" text-anchor="middle">${esc(p.label)}</text>`).join('')}</svg>`;
}

// Seconds as m:ss
export const mmss = (sec) => { const s = Math.max(0, Math.round(sec || 0)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
// 1 switch, 2 switches
export const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
