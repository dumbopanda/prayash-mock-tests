// Run: node util.test.mjs
import assert from 'node:assert/strict';
import { guessValue, qStatus, stateCounts, attemptKind, parseCSV, readQuestions, fmt, phaseOf, chapterStats, strategyStats, subjectStats, mistakes, periodReport, trendSvg, CSV_HEADER, mmss, plural, stratName, barsSvg } from './util.js';

assert.deepEqual(parseCSV('a,"b,c","d ""x"""\n1,2,3\r\n'), [['a', 'b,c', 'd "x"'], ['1', '2', '3']]);
assert.deepEqual(parseCSV('a,"multi\nline"\nz,y'), [['a', 'multi\nline'], ['z', 'y']]);

const csv = CSV_HEADER + '\nPhysics,Motion,"Speed of 2 m/s^2?",1,2,3,4,b,"v = u + at",4\nChem,Acids,Q,a,b,c,d,E,,\nmaths,Alg,Q,a,b,c,d,3,,';
const { ok, errors } = readQuestions(csv);
assert.equal(ok.length, 2);
assert.equal(ok[0].subject, 'physics');
assert.equal(ok[0].correct, 1);
assert.equal(ok[0].marks, 4);
assert.equal(ok[1].subject, 'mathematics');
assert.equal(ok[1].correct, 2);
assert.equal(errors.length, 1);
assert.match(errors[0], /Row 3/);

assert.equal(fmt('x^2 + sqrt(10) <b>'), 'x<sup>2</sup> + √(10) &lt;b&gt;');
assert.equal(fmt('H_2O 10^{-3}'), 'H<sub>2</sub>O 10<sup>-3</sup>');
const MIN = 60000, D = 120 * MIN;
let p = phaseOf('timebox', 0, D);
assert.equal(p.lock, 'physics'); assert.equal(p.idx, 0); assert.equal(p.endsInMs, 25 * MIN);
p = phaseOf('timebox', 26 * MIN, D);
assert.equal(p.lock, 'chemistry'); assert.equal(p.endsInMs, 24 * MIN);
p = phaseOf('timebox', 101 * MIN, D);
assert.equal(p.lock, null); assert.equal(p.idx, 4); assert.ok(p.final);
assert.equal(phaseOf('timebox', 30 * MIN, D, ['biology', 'physics', 'chemistry', 'mathematics']).lock, 'physics');
assert.equal(phaseOf('three_round', 50 * MIN, D).idx, 1);
assert.equal(phaseOf('three_round', 30 * MIN, 60 * MIN).idx, 1); // scaled: 30 of 60 min = 60 of 120
assert.equal(phaseOf('two_pass', 79 * MIN, D).idx, 0);
assert.equal(phaseOf('two_pass', 80 * MIN, D).idx, 1);
assert.equal(phaseOf('subject', 95 * MIN, D).idx, 3);
assert.equal(phaseOf('free', 5 * MIN, D).endsInMs, Infinity);
assert.equal(phaseOf('timebox', D + 5, D).idx, 4); // past the end stays in the last stage
p = phaseOf('timebox', 60 * MIN, D, ['biology']); // single-subject drill: 100 min box, then review
assert.equal(p.lock, 'biology'); assert.equal(p.endsInMs, 40 * MIN);
p = phaseOf('timebox', 55 * MIN, D, ['physics', 'biology']);
assert.equal(p.lock, 'biology'); assert.equal(phaseOf('timebox', 101 * MIN, D, ['physics', 'biology']).lock, null);
assert.equal(stratName('two_pass'), 'Strongest first + two-pass'); assert.equal(stratName('x'), 'x');

// analytics
const row = (attempt_id, question_id, subject, chapter, chosen, correct, submitted_at = '2026-10-20T10:00:00Z') => ({ attempt_id, question_id, subject, chapter, chosen, correct, submitted_at });
const rows = [
  row('a1', 'q1', 'physics', 'Light', 0, 1), row('a1', 'q2', 'physics', 'Light', 1, 1), row('a1', 'q3', 'physics', 'Motion', null, 2),
  row('a1', 'q4', 'biology', 'Cell', 2, 2), row('a1', 'q5', 'biology', 'Cell', 2, 2),
  row('a2', 'q1', 'physics', 'Light', 1, 1, '2026-10-27T10:00:00Z'), // q1 now right
];
const cs = chapterStats(rows);
assert.equal(cs[0].chapter, 'Light'); assert.equal(cs[0].total, 3); assert.equal(cs[0].right, 2);
assert.equal(cs.find((c) => c.chapter === 'Motion'), undefined); // below minTotal
assert.equal(cs.at(-1).chapter, 'Cell'); // strongest last
const atts = [
  { id: 'a1', strategy: 'free', score: 20, max: 40, times: { q1: 60, q2: 60, q3: 120 }, submitted_at: '2026-10-20T10:00:00Z', flags: [{ type: 'tab_hidden' }, { type: 'fullscreen_exit' }, { type: 'fullscreen_exit' }] },
  { id: 'a2', strategy: 'timebox', score: 30, max: 40, times: {}, submitted_at: '2026-10-27T10:00:00Z', flags: [] },
];
const ss = strategyStats(atts);
assert.deepEqual(ss.map((s) => [s.strategy, s.avg]), [['timebox', 75], ['free', 50]]);
const sub = subjectStats(rows.slice(0, 5), atts);
assert.equal(sub[0].subject, 'physics'); assert.equal(sub[0].secs, 240); assert.equal(sub[0].acc, 50); assert.equal(sub[0].skipped, 1);
assert.equal(sub[1].total, 0); assert.equal(sub[1].acc, null);
const mk = mistakes(rows);
assert.deepEqual(mk.map((r) => r.question_id).sort(), ['q3']); // q1 later right, q2/q4/q5 right
assert.equal(mistakes(rows, { q3: Date.parse('2026-10-21T00:00:00Z') }).length, 0); // cleared after the attempt
assert.equal(mistakes(rows, { q3: Date.parse('2026-10-19T00:00:00Z') }).length, 1); // cleared before it: shows again
const pr = periodReport(atts, rows, Date.parse('2026-10-25T00:00:00Z'));
assert.equal(pr.tests, 1); assert.equal(pr.avg, 75); assert.equal(pr.flags.tab_hidden, 0);
const all = periodReport(atts, rows, 0);
assert.equal(all.flags.fullscreen_exit, 2); assert.equal(all.tests, 2);
assert.equal(all.strongest.subject, 'biology');
assert.match(trendSvg([{ label: 'T1', value: 50 }, { label: 'T2', value: 75 }]), /<polyline/);
assert.doesNotMatch(trendSvg([{ label: 'T1', value: 50 }]), /<svg/); // one point: message, not a chart
assert.match(trendSvg([{ label: 'T1', value: 50 }]), /50%/);
assert.equal((barsSvg([0, 3, 1], ['1', '2', '3']).match(/<rect/g) || []).length, 3); assert.match(barsSvg([0, 3], ['a', 'b']), />3</);
assert.equal(mmss(0), '0:00'); assert.equal(mmss(605), '10:05'); assert.equal(mmss(59.6), '1:00');
assert.equal(plural(1, 'switch', 'switches'), '1 switch'); assert.equal(plural(0, 'exit'), '0 exits');
{ const r = readQuestions(CSV_HEADER + '\nphy,c,q,a,b,c,d,B,s,4,fig.png\n'); assert.equal(r.ok[0].image, 'fig.png'); }

// formatting: whole numbers in powers and subscripts, arrows
assert.equal(fmt('6.02 x 10^23'), '6.02 x 10<sup>23</sup>');
assert.equal(fmt('C_12H_22O_11'), 'C<sub>12</sub>H<sub>22</sub>O<sub>11</sub>');
assert.equal(fmt('A + B -> C'), 'A + B → C'); assert.equal(fmt('N_2 + 3H_2 <=> 2NH_3'), 'N<sub>2</sub> + 3H<sub>2</sub> ⇌ 2NH<sub>3</sub>');
assert.equal(fmt('x^-1'), 'x<sup>-1</sup>');
// import warnings
{ const r = readQuestions(CSV_HEADER + '\nphy,,q,a,A,c,d,B,s,4,\n'); assert.equal(r.ok.length, 1); assert.equal(r.warnings.length, 2); assert.equal(r.ok[0].row, 2); }
// palette: answered and marked is its own state
assert.equal(qStatus('a', { a: 0 }, ['a'], []), 'AM'); assert.equal(qStatus('a', {}, ['a'], ['a']), 'M');
assert.equal(qStatus('a', { a: 2 }, [], ['a']), 'A'); assert.equal(qStatus('a', {}, [], ['a']), 'S'); assert.equal(qStatus('a', {}, [], []), 'V');
assert.equal(qStatus('a', { a: 0 }, [], []), 'A'); // option 0 counts as answered
const sc = stateCounts([{ id: 'a', subject: 'physics' }, { id: 'b', subject: 'physics' }, { id: 'c', subject: 'biology' }], { a: 1 }, ['a'], ['b']);
assert.deepEqual(sc.physics, { A: 0, AM: 1, M: 0, S: 1, V: 0 }); assert.equal(sc.biology.V, 1);
assert.equal(attemptKind(1, 1, 60, 120), 'correct'); assert.equal(attemptKind(1, 1, 200, 120), 'correct_slow');
assert.equal(attemptKind(0, 1, 20, 120), 'wrong_fast'); assert.equal(attemptKind(0, 1, 100, 120), 'wrong'); assert.equal(attemptKind(0, 1, 300, 120), 'wrong_slow');
assert.equal(attemptKind(null, 1, 5, 120), 'skipped'); assert.equal(attemptKind(null, 1, 150, 120), 'skipped_late');
assert.equal(guessValue(4, 4, 1), 0.25); assert.equal(guessValue(3, 4, 1), 0.67); assert.equal(guessValue(4, 1, 1), -0.5);
console.log('util ok');
