// Golden "bits" of the definition data (topic "defs_bits" -> godot/tests/golden/defs_bits.json). Godot's JSON parser and
// GDScript float literals are not correctly rounded (about one shortest-repr double in six comes back 1 ulp off), and the
// files under godot/sim/defs/ hold plain decimal numbers. This golden lists the IEEE-754 bits of every non-integer number
// of those files, so tests/test_defs.gd can prove that the doubles the port loads are the original's doubles, bit for bit.
//
// Each entry is "<file>:<dotted path> <16 hex digits>"; array elements are addressed by index. The expected values come from
// the same extraction that writes the defs (tools/extract_defs.mjs), i.e. from the ORIGINAL declarations.
import { hex64 } from './_codec.mjs';
import { extractDefs } from '../extract_defs.mjs';

export const name = 'defs_bits';

function collect(value, path, out) {
  if (typeof value === 'number') {
    if (!Number.isInteger(value) || Object.is(value, -0) || !Number.isFinite(value)) out.push(`${path} ${hex64(value)}`);
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => collect(v, `${path}.${i}`, out));
  } else if (value !== null && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      if (/[.\s]/.test(k)) throw new Error(`key ${JSON.stringify(k)} cannot be used in a dotted path`);
      collect(v, `${path}.${k}`, out);
    }
  }
}

export function generate(_extract) {
  const { files, sourceSha256 } = extractDefs();
  const entries = [];
  for (const [file, data] of files) {
    collect(data.values, `${file}:values`, entries);
    if (data.pointer) collect(data.pointer, `${file}:pointer`, entries);
  }
  return {
    format: 1,
    generated_by: 'tools/golden/defs_bits.mjs',
    source: 'webview-fg4/tests/fixtures/original.html',
    source_sha256: sourceSha256,
    entries,
  };
}
