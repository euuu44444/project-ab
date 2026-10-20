// Reading, writing and decoding swarm-trace/1 files (tools/reference-trace/FORMAT.md). Node 22, standard library only.
//
// A trace is JSON Lines, gzip-compressed (extension .jsonl.gz; a plain .jsonl is read and written as it is). Line 1 is the
// header, every further line is one step. Floats travel as 16 hex digits of the big-endian IEEE-754 bit pattern, so no
// decimal conversion can change a bit.
import fs from 'node:fs';
import zlib from 'node:zlib';

export const TRACE_FORMAT = 'swarm-trace/1';

const dv = new DataView(new ArrayBuffer(8));

/** 16 lowercase hex digits of the bit pattern of `x` (NaN is the canonical 7ff8000000000000). */
export function doubleToHex(x) {
  if (Number.isNaN(x)) return '7ff8000000000000';
  dv.setFloat64(0, x);
  return dv.getUint32(0).toString(16).padStart(8, '0') + dv.getUint32(4).toString(16).padStart(8, '0');
}

/** The double that 16 hex digits stand for. */
export function hexToDouble(hex) {
  if (typeof hex !== 'string' || !/^[0-9a-f]{16}$/.test(hex)) throw new Error(`not a 16-digit hex double: ${JSON.stringify(hex)}`);
  dv.setUint32(0, parseInt(hex.slice(0, 8), 16));
  dv.setUint32(4, parseInt(hex.slice(8), 16));
  return dv.getFloat64(0);
}

/** ["x:f", "level:i", "kind:s"] -> [{ name: "x", type: "f" }, ...]. Types: f float64 (hex), i integer, s string, b boolean. */
export function parseFieldSpec(list) {
  return list.map((entry) => {
    const at = entry.lastIndexOf(':');
    const name = entry.slice(0, at); const type = entry.slice(at + 1);
    if (at <= 0 || !['f', 'i', 's', 'b'].includes(type)) throw new Error(`bad field spec "${entry}" (expected name:type with type f, i, s or b)`);
    return { name, type };
  });
}

/** The decoded value of one field as it is stored in a trace: floats become numbers, everything else is unchanged. */
export function decodeValue(type, stored) {
  return type === 'f' ? hexToDouble(stored) : stored;
}

/** A readable form of a stored value for reports: "12.5 (4029000000000000)" for floats. */
export function describeValue(type, stored) {
  if (type === 'f') return `${formatDouble(hexToDouble(stored))} (${stored})`;
  return JSON.stringify(stored);
}

export function formatDouble(x) {
  return Object.is(x, -0) ? '-0' : String(x);
}

/**
 * Reads a trace. Returns { header, steps, fileBytes, rawBytes }; `steps` are the parsed lines after the header. Throws on a
 * missing or wrong format marker. The gzip layer is detected by the magic bytes, not by the file name.
 */
export function readTrace(file) {
  const fileBytes = fs.readFileSync(file);
  const raw = fileBytes.length >= 2 && fileBytes[0] === 0x1f && fileBytes[1] === 0x8b ? zlib.gunzipSync(fileBytes) : fileBytes;
  const lines = raw.toString('utf8').split('\n').filter((line) => line.length > 0);
  if (lines.length === 0) throw new Error(`${file}: empty trace`);
  const header = JSON.parse(lines[0]);
  if (header.format !== TRACE_FORMAT) throw new Error(`${file}: format is ${JSON.stringify(header.format)}, expected ${TRACE_FORMAT}`);
  const steps = new Array(lines.length - 1);
  for (let i = 1; i < lines.length; i++) steps[i - 1] = JSON.parse(lines[i]);
  return { header, steps, fileBytes: fileBytes.length, rawBytes: raw.length };
}

/**
 * Writes a trace: header object + the already serialised step lines (a string joined by "\n", no trailing newline).
 * Gzip is deterministic (level 9, no timestamp), so the same content gives the same bytes. Returns { fileBytes, rawBytes }.
 */
export function writeTrace(file, header, body) {
  const raw = Buffer.from(`${JSON.stringify(header)}\n${body}\n`, 'utf8');
  const out = file.endsWith('.gz') ? zlib.gzipSync(raw, { level: 9 }) : raw;
  fs.writeFileSync(file, out);
  return { fileBytes: out.length, rawBytes: raw.length };
}

const ZERO_BITS = '0000000000000000';

/**
 * The first steps (1-based; steps + 1 when it never happens) at which a reference trace shows an effect that the port does not
 * have yet, computed from the trace alone (the same definition as godot/tests/test_reference_trace.gd):
 *   contact  enemy/update draws from gameRandom, or the player's hp differs from its value at step 1, or the damage flash is on:
 *            a contact hit, which also pushes the player 22 px (writes x and y);
 *   fire     the player's attackAnim is not 0: a weapon shot (triggerPlayerAttackAnimation sets attackAnim, attackAngle, lastFacing).
 */
export function firstEffects(trace) {
  const { header, steps } = trace;
  const none = steps.length + 1;
  const index = (group, name) => (header.fields[group] || []).findIndex((s) => s.split(':')[0] === name);
  const enemyUpdate = (header.slots?.main || []).indexOf('enemy/update');
  const slotKey = enemyUpdate >= 0 ? `main:${enemyUpdate}` : null;
  const hp = index('player', 'hp'); const attack = index('player', 'attackAnim'); const flash = index('wave', 'damageFlash');
  let contact = none; let fire = none;
  for (let i = 0; i < steps.length && (contact === none || fire === none); i++) {
    const s = steps[i];
    if (contact === none && ((slotKey && (s.slot_draws[slotKey] || 0) !== 0) || (hp >= 0 && s.player[hp] !== steps[0].player[hp]) || (flash >= 0 && s.wave[flash] !== ZERO_BITS))) contact = i + 1;
    if (fire === none && attack >= 0 && s.player[attack] !== ZERO_BITS) fire = i + 1;
  }
  return { contact, fire, steps: steps.length };
}
