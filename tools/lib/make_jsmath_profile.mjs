#!/usr/bin/env node
// Writes the PROFILING copy of godot/sim/js_compat.gd that tools/bench_sim.sh uses to count the JsMath calls of a simulation step
// (design 5.5: "which transcendental functions does a step call, how often"). The production file is never changed and has no counter:
// the copy goes into a throw-away project directory next to a copy of godot/sim and godot/tests/bench.
//
//   node tools/lib/make_jsmath_profile.mjs [--builtin] <godot/sim/js_compat.gd> <out/js_compat.gd>
//
// With --builtin the wrappers do not count: they forward to the engine's own sin, cos, atan, atan2, exp, log, pow, and hypot to sqrt(x*x + y*y)
// (NOT bit-exact). That copy only exists for the experiment "what does the bit-exact math cost" (tools/bench_sim.sh, --mode=steps).
//
// For every function of COUNTED (sin, cos, atan, atan2, exp, log, hypot, pow) the original definition `static func f(...) -> T:` is renamed
// `_raw_f` and a new `f` with the same signature is added at the end of the file: it bumps a counter and calls `_raw_f`. The calls that
// js_compat.gd makes to its own public functions (atan2 -> atan, written `JsMath.atan(`) are redirected to the raw functions, so that only
// calls from the simulation are counted. The counter is the dictionary that the benchmark stores in Engine meta "swarm_bench_jsmath_counts"
// (tests/bench/bench_sim.gd, --mode=count); without that meta the wrappers only forward.
import fs from 'node:fs';

export const COUNTED = ['sin', 'cos', 'atan', 'atan2', 'exp', 'log', 'hypot', 'pow'];
export const COUNT_META = 'swarm_bench_jsmath_counts';

/** @returns {{ source: string, redirected: Record<string, number> }} */
export function makeProfile(source, builtin = false) {
  let out = source;
  const wrappers = [];
  const redirected = {};
  for (const name of COUNTED) {
    const definition = new RegExp(`^static func ${name}\\(([^)]*)\\) -> (\\w+):$`, 'm');
    const found = definition.exec(out);
    if (!found) throw new Error(`js_compat.gd has no "static func ${name}(...) -> T:" line`);
    if (new RegExp(`^static func _raw_${name}\\(`, 'm').test(out)) throw new Error(`js_compat.gd already has a _raw_${name}: not a production file`);
    const [, parameters, returnType] = found;
    const argumentNames = parameters.split(',').map((p) => p.trim().split(':')[0].trim()).filter((p) => p.length > 0);
    out = out.replace(definition, `static func _raw_${name}(${parameters}) -> ${returnType}:`);
    const call = `JsMath.${name}(`;
    redirected[name] = out.split(call).length - 1;
    out = out.split(call).join(`JsMath._raw_${name}(`);
    const body = builtin
      ? `\treturn ${name === 'hypot' ? `sqrt(${argumentNames[0]} * ${argumentNames[0]} + ${argumentNames[1]} * ${argumentNames[1]})` : `${name}(${argumentNames.join(', ')})`}\n`
      : `\t_bench_count("${name}")\n\treturn _raw_${name}(${argumentNames.join(', ')})\n`;
    wrappers.push(`static func ${name}(${parameters}) -> ${returnType}:\n${body}`);
  }
  const counter = builtin
    ? ''
    : `static func _bench_count(function_name: String) -> void:
\tif Engine.has_meta("${COUNT_META}"):
\t\tvar counts: Dictionary = Engine.get_meta("${COUNT_META}")
\t\tcounts[function_name] = int(counts.get(function_name, 0)) + 1


`;
  out = `${out.replace(/\n*$/, '\n')}
# ---------------------------------------------------------------------------------------------------
# ${builtin ? 'BUILTIN-MATH EXPERIMENT' : 'PROFILING BUILD'} (tools/lib/make_jsmath_profile.mjs), not part of the port.
# ---------------------------------------------------------------------------------------------------

${counter}${wrappers.join('\n\n')}`;
  return { source: out, redirected };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const builtin = args[0] === '--builtin';
  if (builtin) args.shift();
  if (args.length !== 2) {
    console.error('usage: node tools/lib/make_jsmath_profile.mjs [--builtin] <godot/sim/js_compat.gd> <out/js_compat.gd>');
    process.exit(2);
  }
  const { source, redirected } = makeProfile(fs.readFileSync(args[0], 'utf8'), builtin);
  fs.writeFileSync(args[1], source);
  console.log(`make_jsmath_profile: ${builtin ? 'builtin forwarding for' : 'counters on'} ${COUNTED.join(', ')}; internal calls redirected to the raw functions: ${JSON.stringify(redirected)}`);
}
