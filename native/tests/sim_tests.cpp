// swarm_sim_tests --golden <dir> [--bench]
//
// The C++ unit tests of native/src/sim (JsMath and the random number generators, step C2). The program is linked from the
// very objects the library links (native/SConstruct) plus the static library libswarm_glibc_sincos.a, and checks them against
// the golden vectors of godot/tests/golden (math.json, rng.json: generated from the original game and checked against
// Chromium 141), bit for bit: doubles are compared by bit pattern, except that any NaN equals any NaN; -0 and +0
// differ. It does what godot/tests/test_js_math.gd and test_rng.gd do for the Godot binding, without Godot, so that it
// also runs for arm64 and armv7 under qemu-user (tools/build_native.sh).
//
// Output: one line per item ("PASS  name  N checks" or "FAIL ..." followed by up to five mismatches with input, expected
// value and result in hex), a SUMMARY line and RESULT: PASS or RESULT: FAIL. The exit code is 0 only for PASS.
// --bench prints the time of the main functions (ns per call); it never fails the run.

#include <chrono>
#include <cinttypes>
#include <cstdarg>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "golden_json.h"
#include "sim/fp_env.h"
#include "sim/fx_rng.h"
#include "sim/game_rng.h"
#include "sim/js_math.h"
#include "sim/seeded_rng.h"

using swarm::sim::FxRng;
using swarm::sim::GameRng;
using swarm::sim::SeededRng;
using golden::Value;
namespace js = swarm::sim::js;

namespace {

// ---- Reporting ---------------------------------------------------------------------------------------------------------

constexpr size_t kMaxReported = 5; // mismatches shown per item

struct Totals {
	uint64_t items = 0;
	uint64_t failed_items = 0;
	uint64_t checks = 0;
	uint64_t failed_checks = 0;
	uint64_t math_rows = 0; // golden rows of math.json that were checked (named cases included)
	uint64_t rng_rows = 0; // golden entries of rng.json that were checked
};

Totals g_totals;

std::string format(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

std::string format(const char *fmt, ...) {
	char buffer[512];
	va_list args;
	va_start(args, fmt);
	std::vsnprintf(buffer, sizeof buffer, fmt, args);
	va_end(args);
	return buffer;
}

std::string hex_of(double x) {
	return format("%016" PRIx64, swarm::sim::to_bits(x));
}

std::string show(double x) {
	return hex_of(x) + " (" + format("%.17g", x) + ")";
}

// Equal bit patterns, except that any NaN equals any NaN (the files store NaN canonically; platforms differ in the payload).
bool same_double(double a, double b) {
	if (a != a) {
		return b != b;
	}
	if (b != b) {
		return false;
	}
	return swarm::sim::to_bits(a) == swarm::sim::to_bits(b);
}

// One item of the report. check() counts a comparison; the first kMaxReported mismatches are kept for the report.
class Item {
public:
	explicit Item(std::string name, bool golden_math = false, bool golden_rng = false) :
			name_(std::move(name)), golden_math_(golden_math), golden_rng_(golden_rng) {}

	Item(const Item &) = delete;
	Item &operator=(const Item &) = delete;

	~Item() {
		if (!finished_) {
			finish();
		}
	}

	template <typename Describe>
	void check(bool ok, Describe describe) {
		++checks_;
		if (!ok) {
			record(describe());
		}
	}

	void check(bool ok, const char *message) {
		check(ok, [&] { return std::string(message); });
	}

	// A failure that is not one comparison of many (a missing member, a vector with too few rows, ...).
	void fail(const std::string &message) {
		++checks_;
		record(message);
	}

	void finish() {
		finished_ = true;
		++g_totals.items;
		g_totals.checks += checks_;
		g_totals.failed_checks += failures_;
		if (golden_math_) {
			g_totals.math_rows += checks_;
		}
		if (golden_rng_) {
			g_totals.rng_rows += checks_;
		}
		if (failures_ == 0 && checks_ > 0) {
			std::printf("PASS  %-34s %8" PRIu64 " checks\n", name_.c_str(), checks_);
		} else {
			++g_totals.failed_items;
			if (checks_ == 0) {
				std::printf("FAIL  %-34s nothing was checked\n", name_.c_str());
			} else {
				std::printf("FAIL  %-34s %8" PRIu64 " of %" PRIu64 " checks differ\n", name_.c_str(), failures_, checks_);
			}
			for (const std::string &line : reported_) {
				std::printf("      %s\n", line.c_str());
			}
			if (failures_ > reported_.size()) {
				std::printf("      ... and %" PRIu64 " more\n", failures_ - reported_.size());
			}
		}
		std::fflush(stdout);
	}

private:
	void record(const std::string &message) {
		++failures_;
		if (reported_.size() < kMaxReported) {
			reported_.push_back(message);
		}
	}

	std::string name_;
	bool golden_math_;
	bool golden_rng_;
	uint64_t checks_ = 0;
	uint64_t failures_ = 0;
	bool finished_ = false;
	std::vector<std::string> reported_;
};

// ---- Golden file access --------------------------------------------------------------------------------------------

bool load_json(const std::string &path, Value *out, Item *item) {
	std::string text;
	std::string error;
	if (!golden::read_file(path, &text, &error)) {
		item->fail(error);
		return false;
	}
	if (!golden::parse(text, out, &error)) {
		item->fail(path + ": " + error);
		return false;
	}
	if (!out->is(Value::Type::Object)) {
		item->fail(path + ": the document is not an object");
		return false;
	}
	return true;
}

// Reads a 16 digit hex string (the bit pattern of a double, upper or lower case).
bool parse_hex_bits(const std::string &text, uint64_t *out) {
	if (text.size() != 16) {
		return false;
	}
	uint64_t v = 0;
	for (char c : text) {
		uint64_t d;
		if (c >= '0' && c <= '9') {
			d = static_cast<uint64_t>(c - '0');
		} else if (c >= 'a' && c <= 'f') {
			d = static_cast<uint64_t>(c - 'a' + 10);
		} else if (c >= 'A' && c <= 'F') {
			d = static_cast<uint64_t>(c - 'A' + 10);
		} else {
			return false;
		}
		v = (v << 4) | d;
	}
	*out = v;
	return true;
}

bool hex_double(const Value *v, double *out) {
	uint64_t bits;
	if (v == nullptr || !v->is(Value::Type::String) || !parse_hex_bits(v->string, &bits)) {
		return false;
	}
	*out = swarm::sim::from_bits(bits);
	return true;
}

bool as_int(const Value *v, int64_t *out) {
	if (v == nullptr || !v->is(Value::Type::Int)) {
		return false;
	}
	*out = v->integer;
	return true;
}

uint32_t le_u32(const uint8_t *p) {
	return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

uint64_t le_u64(const uint8_t *p) {
	return static_cast<uint64_t>(le_u32(p)) | (static_cast<uint64_t>(le_u32(p + 4)) << 32);
}

// base64 of little-endian doubles / int32 / uint32
bool decode_f64(const Value *v, std::vector<double> *out) {
	std::vector<uint8_t> bytes;
	if (v == nullptr || !v->is(Value::Type::String) || !golden::base64_decode(v->string, &bytes) || bytes.size() % 8 != 0) {
		return false;
	}
	out->clear();
	out->reserve(bytes.size() / 8);
	for (size_t i = 0; i < bytes.size(); i += 8) {
		out->push_back(swarm::sim::from_bits(le_u64(&bytes[i])));
	}
	return true;
}

bool decode_u32(const Value *v, std::vector<uint32_t> *out) {
	std::vector<uint8_t> bytes;
	if (v == nullptr || !v->is(Value::Type::String) || !golden::base64_decode(v->string, &bytes) || bytes.size() % 4 != 0) {
		return false;
	}
	out->clear();
	out->reserve(bytes.size() / 4);
	for (size_t i = 0; i < bytes.size(); i += 4) {
		out->push_back(le_u32(&bytes[i]));
	}
	return true;
}

// A double that is known to hold an integer of the golden files into int64; false when it does not fit (or is NaN).
bool double_to_int64(double v, int64_t *out) {
	if (!(v >= -9223372036854775808.0 && v < 9223372036854775808.0)) {
		return false;
	}
	*out = static_cast<int64_t>(v);
	return true;
}

// ---- math.json: the vectors ----------------------------------------------------------------------------------------

constexpr size_t kMaxArgs = 5;
constexpr size_t kPortedMinRows = 20000;
constexpr size_t kWrapperMinRows = 2048;
constexpr size_t kPowMinRows = 490;

using F64Fn = double (*)(const double *a);
// The integer functions take their arguments as doubles from the golden files (integers of any size a double holds).
// They return false when an argument is not an integer that fits an int64.
using IntFn = bool (*)(const double *a, int64_t *result);

struct VectorCase {
	const char *label; // the item name
	const char *vector; // the name in math.json
	size_t min_rows;
	size_t arity; // how many columns of a row the function takes
	const char *output_type; // "f64", "i32" or "u32"
	F64Fn f64;
	IntFn integer;
};

bool int_args(const double *a, size_t n, int64_t *out) {
	for (size_t i = 0; i < n; ++i) {
		if (!double_to_int64(a[i], &out[i])) {
			return false;
		}
	}
	return true;
}

// Every function of math.json. The table is also what is compared with the file: a vector the file has and the table
// lacks (or the other way round) is a failure, so a new vector cannot be forgotten.
const VectorCase kVectorCases[] = {
	{ "sin", "sin", kPortedMinRows, 1, "f64", [](const double *a) { return js::sin(a[0]); }, nullptr },
	{ "cos", "cos", kPortedMinRows, 1, "f64", [](const double *a) { return js::cos(a[0]); }, nullptr },
	{ "atan", "atan", kPortedMinRows, 1, "f64", [](const double *a) { return js::atan(a[0]); }, nullptr },
	{ "exp", "exp", kPortedMinRows, 1, "f64", [](const double *a) { return js::exp(a[0]); }, nullptr },
	{ "log", "log", kPortedMinRows, 1, "f64", [](const double *a) { return js::log(a[0]); }, nullptr },
	{ "atan2", "atan2", kPortedMinRows, 2, "f64", [](const double *a) { return js::atan2(a[0], a[1]); }, nullptr },
	{ "hypot", "hypot", kPortedMinRows, 2, "f64", [](const double *a) { return js::hypot(a[0], a[1]); }, nullptr },
	{ "mod", "mod", kPortedMinRows, 2, "f64", [](const double *a) { return js::mod(a[0], a[1]); }, nullptr },
	{ "max", "max", kPortedMinRows, 2, "f64", [](const double *a) { return js::max(a[0], a[1]); }, nullptr },
	{ "min", "min", kPortedMinRows, 2, "f64", [](const double *a) { return js::min(a[0], a[1]); }, nullptr },
	{ "round", "round", kPortedMinRows, 1, "f64", [](const double *a) { return js::round(a[0]); }, nullptr },
	{ "trunc", "trunc", kPortedMinRows, 1, "f64", [](const double *a) { return js::trunc(a[0]); }, nullptr },
	{ "to_int32", "to_int32", kPortedMinRows, 1, "i32", nullptr, [](const double *a, int64_t *r) { *r = js::to_int32(a[0]); return true; } },
	{ "to_uint32", "to_uint32", kPortedMinRows, 1, "u32", nullptr, [](const double *a, int64_t *r) { *r = js::to_uint32(a[0]); return true; } },
	{ "floor", "floor", kWrapperMinRows, 1, "f64", [](const double *a) { return js::floor(a[0]); }, nullptr },
	{ "ceil", "ceil", kWrapperMinRows, 1, "f64", [](const double *a) { return js::ceil(a[0]); }, nullptr },
	{ "sqrt", "sqrt", kWrapperMinRows, 1, "f64", [](const double *a) { return js::sqrt(a[0]); }, nullptr },
	{ "abs", "abs", kWrapperMinRows, 1, "f64", [](const double *a) { return js::abs(a[0]); }, nullptr },
	{ "imul", "imul", kPortedMinRows, 2, "i32", nullptr, [](const double *a, int64_t *r) { int64_t v[2]; if (!int_args(a, 2, v)) { return false; } *r = js::imul(v[0], v[1]); return true; } },
	{ "shl", "shl", kPortedMinRows, 2, "i32", nullptr, [](const double *a, int64_t *r) { int64_t v[2]; if (!int_args(a, 2, v)) { return false; } *r = js::shl(v[0], v[1]); return true; } },
	{ "sar", "sar", kPortedMinRows, 2, "i32", nullptr, [](const double *a, int64_t *r) { int64_t v[2]; if (!int_args(a, 2, v)) { return false; } *r = js::sar(v[0], v[1]); return true; } },
	{ "shr_u", "shr_u", kPortedMinRows, 2, "u32", nullptr, [](const double *a, int64_t *r) { int64_t v[2]; if (!int_args(a, 2, v)) { return false; } *r = js::shr_u(v[0], v[1]); return true; } },
	{ "max3", "max3", kPortedMinRows, 3, "f64", [](const double *a) { return js::max3(a[0], a[1], a[2]); }, nullptr },
	{ "min3", "min3", kPortedMinRows, 3, "f64", [](const double *a) { return js::min3(a[0], a[1], a[2]); }, nullptr },
	{ "max5", "max5", kPortedMinRows, 5, "f64", [](const double *a) { return js::max5(a[0], a[1], a[2], a[3], a[4]); }, nullptr },
	{ "min5", "min5", kPortedMinRows, 5, "f64", [](const double *a) { return js::min5(a[0], a[1], a[2], a[3], a[4]); }, nullptr },
	{ "clamp", "clamp", kPortedMinRows, 3, "f64", [](const double *a) { return js::clamp(a[0], a[1], a[2]); }, nullptr },
	{ "pow", "pow", kPowMinRows, 2, "f64", [](const double *a) { return js::pow(a[0], a[1]); }, nullptr },
	// max_n and min_n take an array: they are checked on the inputs and results of max5 and min5.
	{ "max_n (max5 vector)", "max5", kPortedMinRows, 5, "f64", [](const double *a) { return js::max_n(a, 5); }, nullptr },
	{ "min_n (min5 vector)", "min5", kPortedMinRows, 5, "f64", [](const double *a) { return js::min_n(a, 5); }, nullptr },
};

// How many of the cases are the 28 vectors of the file (the last two reuse max5 and min5).
constexpr size_t kFileVectorCount = 28;

void check_vector(const VectorCase &c, const Value &math, bool *vector_found) {
	std::string name = std::string("math.") + c.label;
	Item item(name, true);
	*vector_found = false;
	const Value *vectors = math.find("vectors");
	const Value *inputs = math.find("inputs");
	const Value *vector = vectors != nullptr ? vectors->find(c.vector) : nullptr;
	if (vector == nullptr) {
		item.fail(std::string("the file has no vector '") + c.vector + "'");
		return;
	}
	*vector_found = true;
	const Value *input_name = vector->find("input");
	const Value *rows_value = vector->find("rows");
	const Value *output_type = vector->find("output_type");
	int64_t rows64;
	if (input_name == nullptr || !input_name->is(Value::Type::String) || !as_int(rows_value, &rows64) || rows64 < 0 || output_type == nullptr || !output_type->is(Value::Type::String)) {
		item.fail("the vector lacks input, rows or output_type");
		return;
	}
	size_t rows = static_cast<size_t>(rows64);
	const Value *input_set = inputs != nullptr ? inputs->find(input_name->string) : nullptr;
	const Value *type_of_input = input_set != nullptr ? input_set->find("type") : nullptr;
	const Value *columns_value = input_set != nullptr ? input_set->find("columns") : nullptr;
	if (type_of_input == nullptr || type_of_input->string != "f64" || columns_value == nullptr || !columns_value->is(Value::Type::Array)) {
		item.fail("input set '" + input_name->string + "' is missing or not f64");
		return;
	}
	std::vector<std::vector<double>> columns(columns_value->array.size());
	for (size_t i = 0; i < columns.size(); ++i) {
		if (!decode_f64(&columns_value->array[i], &columns[i])) {
			item.fail("cannot decode column " + std::to_string(i) + " of input set '" + input_name->string + "'");
			return;
		}
		if (columns[i].size() < rows) {
			item.fail("column " + std::to_string(i) + " of the input set has fewer rows than the vector");
			return;
		}
	}
	if (rows < c.min_rows) {
		item.fail(format("the vector has only %zu rows, at least %zu are required", rows, c.min_rows));
		return;
	}
	if (output_type->string != c.output_type) {
		item.fail("output_type is '" + output_type->string + "', the test expects '" + c.output_type + "'");
		return;
	}
	if (c.arity > columns.size() || c.arity > kMaxArgs) {
		item.fail(format("the function takes %zu arguments, the input set has %zu columns", c.arity, columns.size()));
		return;
	}
	std::vector<double> expected_f64;
	std::vector<uint32_t> expected_int;
	const Value *output = vector->find("output");
	if (c.f64 != nullptr) {
		if (!decode_f64(output, &expected_f64) || expected_f64.size() < rows) {
			item.fail("cannot decode the expected values");
			return;
		}
	} else if (!decode_u32(output, &expected_int) || expected_int.size() < rows) {
		item.fail("cannot decode the expected values");
		return;
	}
	const bool is_unsigned = std::strcmp(c.output_type, "u32") == 0;
	for (size_t i = 0; i < rows; ++i) {
		double a[kMaxArgs] = { 0.0, 0.0, 0.0, 0.0, 0.0 };
		for (size_t k = 0; k < c.arity; ++k) {
			a[k] = columns[k][i];
		}
		auto args_text = [&] {
			std::string text;
			for (size_t k = 0; k < c.arity; ++k) {
				text += (k == 0 ? "" : ", ") + show(a[k]);
			}
			return text;
		};
		if (c.f64 != nullptr) {
			double got = c.f64(a);
			item.check(same_double(got, expected_f64[i]), [&] { return format("row %zu: args [%s] expected %s but got %s", i, args_text().c_str(), show(expected_f64[i]).c_str(), show(got).c_str()); });
		} else {
			int64_t got = 0;
			bool valid = c.integer(a, &got);
			int64_t want = is_unsigned ? static_cast<int64_t>(expected_int[i]) : static_cast<int64_t>(swarm::sim::as_int32(expected_int[i]));
			item.check(valid && got == want, [&] { return format("row %zu: args [%s] expected %" PRId64 " but got %" PRId64 "%s", i, args_text().c_str(), want, got, valid ? "" : " (argument not an int64)"); });
		}
	}
}

void check_math_vectors(const Value &math) {
	bool found_in_file[kFileVectorCount + 2] = {};
	size_t file_cases = 0;
	for (size_t i = 0; i < sizeof(kVectorCases) / sizeof(kVectorCases[0]); ++i) {
		bool found = false;
		check_vector(kVectorCases[i], math, &found);
		found_in_file[i] = found;
		if (i < kFileVectorCount && found) {
			++file_cases;
		}
	}
	// The file may not hold a vector that no case checks.
	Item coverage("math.every vector of the file is checked");
	const Value *vectors = math.find("vectors");
	if (vectors == nullptr || !vectors->is(Value::Type::Object)) {
		coverage.fail("the file has no 'vectors' object");
		return;
	}
	coverage.check(vectors->keys.size() == kFileVectorCount, [&] { return format("the file has %zu vectors, the tests know %zu", vectors->keys.size(), kFileVectorCount); });
	for (const std::string &key : vectors->keys) {
		bool known = false;
		for (size_t i = 0; i < kFileVectorCount; ++i) {
			if (key == kVectorCases[i].vector) {
				known = true;
			}
		}
		coverage.check(known, [&] { return "the file has a vector '" + key + "' that no test checks"; });
	}
	coverage.check(file_cases == kFileVectorCount, [&] { return format("%zu of the %zu vectors were checked", file_cases, kFileVectorCount); });
}

// ---- math.json: the named cases ------------------------------------------------------------------------------------

bool call_named(const std::string &fn, const std::vector<double> &a, double *out) {
	auto need = [&](size_t n) { return a.size() >= n; };
	if (fn == "sin" && need(1)) { *out = js::sin(a[0]); return true; }
	if (fn == "cos" && need(1)) { *out = js::cos(a[0]); return true; }
	if (fn == "round" && need(1)) { *out = js::round(a[0]); return true; }
	if (fn == "max" && need(2)) { *out = js::max(a[0], a[1]); return true; }
	if (fn == "min" && need(2)) { *out = js::min(a[0], a[1]); return true; }
	if (fn == "clamp" && need(3)) { *out = js::clamp(a[0], a[1], a[2]); return true; }
	if (fn == "mod" && need(2)) { *out = js::mod(a[0], a[1]); return true; }
	if (fn == "hypot" && need(2)) { *out = js::hypot(a[0], a[1]); return true; }
	if (fn == "atan2" && need(2)) { *out = js::atan2(a[0], a[1]); return true; }
	if (fn == "exp" && need(1)) { *out = js::exp(a[0]); return true; }
	if (fn == "pow" && need(2)) { *out = js::pow(a[0], a[1]); return true; }
	if (fn == "to_int32" && need(1)) { *out = static_cast<double>(js::to_int32(a[0])); return true; }
	if (fn == "to_uint32" && need(1)) { *out = static_cast<double>(js::to_uint32(a[0])); return true; }
	if (fn == "imul" && need(2)) {
		int64_t x;
		int64_t y;
		if (!double_to_int64(a[0], &x) || !double_to_int64(a[1], &y)) {
			return false;
		}
		*out = static_cast<double>(js::imul(x, y));
		return true;
	}
	return false;
}

void check_named_cases(const Value &math) {
	Item item("math.named pitfall cases", true);
	const Value *named = math.find("named");
	if (named == nullptr || !named->is(Value::Type::Array)) {
		item.fail("the file has no 'named' array");
		return;
	}
	item.check(named->array.size() >= 48, [&] { return format("the file has only %zu named cases", named->array.size()); });
	for (const Value &entry : named->array) {
		if (!entry.is(Value::Type::Array) || entry.array.size() != 4 || !entry.array[0].is(Value::Type::String) || !entry.array[1].is(Value::Type::String) || !entry.array[2].is(Value::Type::Array)) {
			item.fail("a named case is not [label, function, [args], expected]");
			continue;
		}
		const std::string &label = entry.array[0].string;
		std::vector<double> args;
		bool well_formed = true;
		for (const Value &hex : entry.array[2].array) {
			double d;
			if (!hex_double(&hex, &d)) {
				well_formed = false;
				break;
			}
			args.push_back(d);
		}
		double expected;
		if (!well_formed || !hex_double(&entry.array[3], &expected)) {
			item.fail(label + ": arguments or expected value are not 16 hex digits");
			continue;
		}
		double got = 0.0;
		if (!call_named(entry.array[1].string, args, &got)) {
			item.fail(label + ": unknown function '" + entry.array[1].string + "' or arguments not usable");
			continue;
		}
		item.check(same_double(got, expected), [&] { return label + ": expected " + show(expected) + " but got " + show(got); });
	}
}

// ---- math: max_n / min_n of nothing ------------------------------------------------------------------------------

void check_empty_max_min() {
	// Math.max() is -Infinity and Math.min() is Infinity; the five-value cases are checked on the max5 and min5 vectors above.
	Item item("math.max_n and min_n of an empty array");
	const double infinity = std::numeric_limits<double>::infinity();
	const double one[1] = { 1.0 };
	item.check(js::max_n(nullptr, 0) == -infinity, "Math.max() is -Infinity");
	item.check(js::min_n(nullptr, 0) == infinity, "Math.min() is Infinity");
	item.check(js::max_n(one, 1) == 1.0 && js::min_n(one, 1) == 1.0, "one value");
}

// ---- math: i32 boundaries, bit helpers ---------------------------------------------------------------------------

void check_i32_boundaries() {
	// JavaScript: (v | 0) for integer-valued v. The golden vectors cover the doubles; this covers ints beyond 2^53.
	Item item("math.i32 wraps to the int32 range");
	const int64_t int64_min = -9223372036854775807 - 1;
	const int64_t cases[] = { 0, 1, -1, 2147483647, 2147483648, -2147483648, -2147483649, 4294967295, 4294967296, 9223372036854775807, int64_min };
	const int32_t expected[] = { 0, 1, -1, 2147483647, -2147483647 - 1, -2147483647 - 1, 2147483647, -1, 0, -1, 0 };
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
		int32_t got = js::i32(cases[i]);
		item.check(got == expected[i], [&] { return format("i32(%" PRId64 ") expected %d but got %d", cases[i], static_cast<int>(expected[i]), static_cast<int>(got)); });
	}
}

void check_bit_helpers() {
	Item item("math.bit helpers and negative zero");
	item.check(hex_of(js::neg_zero()) == "8000000000000000", "neg_zero() is -0");
	item.check(hex_of(0.0) == "0000000000000000", "0.0 is all zero bits");
	item.check(js::to_bits(1.0) == UINT64_C(0x3FF0000000000000), "to_bits(1.0)");
	item.check(js::from_bits(UINT64_C(0x3FF0000000000000)) == 1.0, "from_bits(0x3FF0000000000000)");
	item.check(js::to_bits(-2.0) == UINT64_C(0xC000000000000000), "-2.0 is 0xC000000000000000");
	item.check(static_cast<int64_t>(js::to_bits(-2.0)) == -4611686018427387904, "-2.0 as a signed int64 (what SwarmJsMath.to_bits returns)");
	item.check(js::high_word(1.0) == 0x3FF00000u, "high_word(1.0)");
	const double values[] = { 0.1, -0.1, 1e300, 5e-324, 123456.789 };
	for (double x : values) {
		item.check(js::from_bits(js::to_bits(x)) == x, [&] { return "from_bits(to_bits(" + show(x) + "))"; });
	}
}

// ---- rng.json ------------------------------------------------------------------------------------------------------------

constexpr int64_t kCheckpointFullLengthSeed = 424242;

void check_first_outputs(const Value &rng) {
	Item item("rng.first 1000 outputs of every seed", false, true);
	const Value *length_value = rng.find("stream_length");
	const Value *seeds = rng.find("seeds");
	int64_t length;
	if (!as_int(length_value, &length) || length != 1000 || seeds == nullptr || !seeds->is(Value::Type::Array)) {
		item.fail("stream_length is not 1000 or there is no 'seeds' array");
		return;
	}
	item.check(seeds->array.size() >= 8, "at least the eight seeds of the design are covered");
	bool seen[5] = {};
	const int64_t required[5] = { 424242, 24681357, 0, 1, 0xFFFFFFFF };
	for (const Value &entry : seeds->array) {
		int64_t seed;
		int64_t normalized;
		std::vector<uint32_t> first;
		if (!as_int(entry.find("seed"), &seed) || !as_int(entry.find("normalized"), &normalized) || !decode_u32(entry.find("first"), &first) || first.size() != static_cast<size_t>(length)) {
			item.fail("a seed entry lacks seed, normalized or 1000 outputs");
			continue;
		}
		for (size_t r = 0; r < 5; ++r) {
			if (seed == required[r]) {
				seen[r] = true;
			}
		}
		item.check(static_cast<int64_t>(SeededRng::normalize_seed(static_cast<double>(seed))) == normalized, [&] { return format("seed %" PRId64 ": normalize_seed", seed); });
		SeededRng rng_u32(seed);
		SeededRng rng_float(seed);
		for (size_t i = 0; i < first.size(); ++i) {
			uint32_t k = rng_u32.next_u32();
			double f = rng_float.next_float();
			bool ok = k == first[i] && same_double(f, static_cast<double>(first[i]) / 4294967296.0);
			item.check(ok, [&] { return format("seed %" PRId64 " output %zu: expected k=%u but got k=%u (float %s)", seed, i, first[i], k, show(f).c_str()); });
		}
	}
	// The seeds that the task and the reference traces name.
	for (size_t r = 0; r < 5; ++r) {
		item.check(seen[r], [&] { return format("seed %" PRId64 " is not in the golden file", required[r]); });
	}
}

void check_checkpoints(const Value &rng) {
	// The stream is continued to the checkpoints recorded from the original (outputs number 9999 and 99999, and for one
	// seed number 999999), which catches a drift of the state that the first 1000 values would not show.
	Item item("rng.later outputs match the checkpoints", false, true);
	const Value *seeds = rng.find("seeds");
	if (seeds == nullptr || !seeds->is(Value::Type::Array)) {
		item.fail("there is no 'seeds' array");
		return;
	}
	for (const Value &entry : seeds->array) {
		int64_t seed;
		const Value *checkpoints = entry.find("checkpoints");
		if (!as_int(entry.find("seed"), &seed) || checkpoints == nullptr || !checkpoints->is(Value::Type::Object)) {
			item.fail("a seed entry lacks seed or checkpoints");
			continue;
		}
		std::vector<std::pair<uint64_t, int64_t>> wanted; // (index, k)
		bool well_formed = true;
		for (size_t i = 0; i < checkpoints->keys.size(); ++i) {
			int64_t k;
			const std::string &key = checkpoints->keys[i];
			if (key.empty() || key.size() > 9 || key.find_first_not_of("0123456789") != std::string::npos || !as_int(&checkpoints->members[i], &k)) {
				well_formed = false;
				break;
			}
			wanted.emplace_back(static_cast<uint64_t>(std::stoull(key)), k);
		}
		if (!well_formed) {
			item.fail(format("seed %" PRId64 ": a checkpoint key or value is not an integer", seed));
			continue;
		}
		uint64_t last = 99999;
		if (checkpoints->find("999999") != nullptr) {
			item.check(seed == kCheckpointFullLengthSeed, "only the first reference seed has the long checkpoint");
			last = 999999;
		}
		item.check(checkpoints->find(std::to_string(last)) != nullptr, [&] { return format("seed %" PRId64 ": checkpoint %" PRIu64 " does not exist", seed, last); });
		SeededRng rng_u32(seed);
		for (uint64_t i = 0; i <= last; ++i) {
			uint32_t k = rng_u32.next_u32();
			for (const auto &w : wanted) {
				if (w.first == i) {
					item.check(static_cast<int64_t>(k) == w.second, [&] { return format("seed %" PRId64 " output %" PRIu64 ": expected %" PRId64 " but got %u", seed, i, w.second, k); });
				}
			}
		}
	}
}

void check_normalization(const Value &rng) {
	// `seed>>>0||2654435769`: negative, fractional, NaN, huge and infinite seeds, as the original treats them.
	Item item("rng.seed normalisation", false, true);
	const Value *cases = rng.find("normalization");
	if (cases == nullptr || !cases->is(Value::Type::Array)) {
		item.fail("there is no 'normalization' array");
		return;
	}
	item.check(cases->array.size() >= 17, [&] { return format("only %zu normalisation cases", cases->array.size()); });
	for (const Value &entry : cases->array) {
		double input;
		int64_t normalized;
		const Value *first = entry.find("first");
		if (!hex_double(entry.find("input"), &input) || !as_int(entry.find("normalized"), &normalized) || first == nullptr || !first->is(Value::Type::Array)) {
			item.fail("a normalisation case lacks input, normalized or first");
			continue;
		}
		int64_t got = static_cast<int64_t>(SeededRng::normalize_seed(input));
		item.check(got == normalized, [&] { return "normalize_seed(" + show(input) + ") expected " + std::to_string(normalized) + " but got " + std::to_string(got); });
		SeededRng generator(normalized);
		for (size_t i = 0; i < first->array.size(); ++i) {
			int64_t want;
			if (!as_int(&first->array[i], &want)) {
				item.fail("a 'first' output is not an integer");
				continue;
			}
			uint32_t k = generator.next_u32();
			item.check(static_cast<int64_t>(k) == want, [&] { return "seed " + show(input) + ", output " + std::to_string(i) + ": expected " + std::to_string(want) + " but got " + std::to_string(k); });
		}
	}
}

void check_equal_streams() {
	// 0, 2654435769 and 4294967296 are the same seed for the original (and so are -1 and 4294967295).
	Item item("rng.seeds that normalise alike", false, true);
	SeededRng a(0);
	SeededRng b(2654435769);
	SeededRng c(4294967296);
	SeededRng d(-1);
	SeededRng e(4294967295);
	for (int i = 0; i < 50; ++i) {
		uint32_t k = a.next_u32();
		item.check(b.next_u32() == k, "2654435769 differs from 0");
		item.check(c.next_u32() == k, "4294967296 differs from 0");
		item.check(d.next_u32() == e.next_u32(), "-1 differs from 4294967295");
	}
}

void check_state_save_restore() {
	Item item("rng.state can be saved and restored", false, true);
	SeededRng rng(24681357);
	for (int i = 0; i < 37; ++i) {
		rng.next_u32();
	}
	int32_t saved = rng.state();
	uint32_t expected[20];
	for (uint32_t &k : expected) {
		k = rng.next_u32();
	}
	SeededRng other(1);
	other.set_state(saved);
	for (int i = 0; i < 20; ++i) {
		item.check(other.next_u32() == expected[i], [&] { return format("output %d after restoring the state", i); });
	}
	other.set_seed(24681357);
	SeededRng fresh(24681357);
	item.check(other.next_u32() == fresh.next_u32(), "set_seed restarts the stream");
	// The state is an int32: a state above 2^31 reads back negative, and writing it back gives the same stream.
	SeededRng wrap(0);
	wrap.set_state(-2147483647 - 1);
	item.check(wrap.state() == -2147483647 - 1, "state holds the full int32 range");
	SeededRng seeded(2147483648);
	item.check(seeded.state() == -2147483647 - 1, "seed 2147483648 is state -2^31");
}

// The operations of the game_rng sequences. Returns false if the entry is malformed.
bool run_game_op(GameRng &game, const Value &op, std::string *got_text, bool *ok, int64_t *expected_draws, std::string *name_out, std::string *expected_text) {
	if (!op.is(Value::Type::Array) || op.array.size() != 4 || !op.array[0].is(Value::Type::String) || !op.array[1].is(Value::Type::Array) || !as_int(&op.array[3], expected_draws)) {
		return false;
	}
	const std::string &name = op.array[0].string;
	const std::vector<Value> &args = op.array[1].array;
	const Value &expected = op.array[2];
	*name_out = name;
	*ok = false;
	if (name == "random" && args.empty()) {
		double want;
		if (!hex_double(&expected, &want)) {
			return false;
		}
		double r = game.random();
		*ok = same_double(r, want);
		*got_text = show(r);
		*expected_text = show(want);
		return true;
	}
	if (name == "rand" && args.size() == 2) {
		double a;
		double b;
		double want;
		if (!hex_double(&args[0], &a) || !hex_double(&args[1], &b) || !hex_double(&expected, &want)) {
			return false;
		}
		double r = game.rand(a, b);
		*ok = same_double(r, want);
		*got_text = show(r);
		*expected_text = show(want);
		return true;
	}
	if (name == "randi" && args.size() == 2) {
		int64_t a;
		int64_t b;
		int64_t want;
		if (!as_int(&args[0], &a) || !as_int(&args[1], &b) || !as_int(&expected, &want)) {
			return false;
		}
		int64_t r = game.randi(a, b);
		*ok = r == want;
		*got_text = std::to_string(r);
		*expected_text = std::to_string(want);
		return true;
	}
	if (name == "chance" && args.size() == 1) {
		double p;
		if (!hex_double(&args[0], &p) || !expected.is(Value::Type::Bool)) {
			return false;
		}
		bool r = game.chance(p);
		*ok = r == expected.boolean;
		*got_text = r ? "true" : "false";
		*expected_text = expected.boolean ? "true" : "false";
		return true;
	}
	if (name == "shuffle" && args.size() == 1) {
		int64_t n;
		if (!as_int(&args[0], &n) || n < 0 || n > 100000 || !expected.is(Value::Type::Array)) {
			return false;
		}
		std::vector<int64_t> items(static_cast<size_t>(n));
		for (size_t j = 0; j < items.size(); ++j) {
			items[j] = static_cast<int64_t>(j);
		}
		game.shuffle(items.data(), items.size());
		bool same = items.size() == expected.array.size();
		for (size_t j = 0; same && j < items.size(); ++j) {
			int64_t want;
			if (!as_int(&expected.array[j], &want)) {
				return false;
			}
			same = items[j] == want;
		}
		*ok = same;
		*got_text = "a shuffle of " + std::to_string(n) + " elements";
		*expected_text = "the recorded order";
		return true;
	}
	if (name == "index" && args.size() == 1) {
		int64_t length;
		int64_t want;
		if (!as_int(&args[0], &length) || !as_int(&expected, &want)) {
			return false;
		}
		int64_t r = game.index(length);
		*ok = r == want;
		*got_text = std::to_string(r);
		*expected_text = std::to_string(want);
		return true;
	}
	if (name == "reseed" && args.size() == 1) {
		int64_t seed;
		int64_t want;
		if (!as_int(&args[0], &seed) || !as_int(&expected, &want)) {
			return false;
		}
		game.set_seed(seed);
		*ok = static_cast<int64_t>(game.seed_value()) == want;
		*got_text = std::to_string(game.seed_value());
		*expected_text = std::to_string(want);
		return true;
	}
	return false;
}

void check_game_rng_sequences(const Value &rng) {
	Item item("rng.GameRng helpers and draw counter", false, true);
	const Value *sequences = rng.find("game_rng");
	if (sequences == nullptr || !sequences->is(Value::Type::Array)) {
		item.fail("there is no 'game_rng' array");
		return;
	}
	item.check(sequences->array.size() >= 5, [&] { return format("only %zu operation sequences", sequences->array.size()); });
	for (const Value &sequence : sequences->array) {
		int64_t seed;
		const Value *initial = sequence.find("initial");
		const Value *ops = sequence.find("ops");
		int64_t initial_draws;
		int64_t initial_seed_value;
		if (!as_int(sequence.find("seed"), &seed) || initial == nullptr || !as_int(initial->find("draws"), &initial_draws) || !as_int(initial->find("seed_value"), &initial_seed_value) || ops == nullptr || !ops->is(Value::Type::Array)) {
			item.fail("a sequence lacks seed, initial or ops");
			continue;
		}
		item.check(ops->array.size() >= 400, [&] { return format("seed %" PRId64 ": only %zu operations", seed, ops->array.size()); });
		GameRng game(12345); // deliberately another seed first: set_seed must start the stream over
		game.random();
		game.set_seed(seed);
		item.check(game.draws() == initial_draws, [&] { return format("seed %" PRId64 ": draws right after set_seed", seed); });
		item.check(static_cast<int64_t>(game.seed_value()) == initial_seed_value, [&] { return format("seed %" PRId64 ": gameRandomSeed", seed); });
		size_t index = 0;
		for (const Value &op : ops->array) {
			std::string got_text;
			std::string expected_text;
			std::string name;
			bool ok = false;
			int64_t expected_draws = 0;
			if (!run_game_op(game, op, &got_text, &ok, &expected_draws, &name, &expected_text)) {
				item.fail(format("seed %" PRId64 " op %zu is not a known operation or is malformed", seed, index));
				++index;
				continue;
			}
			bool draws_ok = game.draws() == expected_draws;
			item.check(ok && draws_ok, [&] { return format("seed %" PRId64 " op %zu %s: expected %s but got %s (draws %" PRId64 ", expected %" PRId64 ")", seed, index, name.c_str(), expected_text.c_str(), got_text.c_str(), game.draws(), expected_draws); });
			++index;
		}
	}
}

void check_helper_draw_counts() {
	// The counts are those of the original (verified by the replay above); stated here so that a failure names the helper.
	Item item("rng.every helper draws as often as the original");
	GameRng game(424242);
	item.check(game.draws() == 0, "a new generator has drawn nothing");
	game.random();
	item.check(game.draws() == 1, "random draws once");
	game.rand(0.0, 1.0);
	item.check(game.draws() == 2, "rand draws once");
	game.randi(1, 6);
	item.check(game.draws() == 3, "randi draws once");
	game.chance(0.0);
	item.check(game.draws() == 4, "chance draws even when the probability is 0");
	game.chance(1.0);
	item.check(game.draws() == 5, "chance(1) draws once");
	game.index(4);
	item.check(game.draws() == 6, "index draws once");
	int empty_items[1] = { 0 };
	int one_item[1] = { 1 };
	game.shuffle(empty_items, 0);
	game.shuffle(one_item, 1);
	item.check(game.draws() == 6, "shuffle of 0 or 1 elements draws nothing");
	int five[5] = { 1, 2, 3, 4, 5 };
	game.shuffle(five, 5);
	item.check(game.draws() == 10, "shuffle draws length - 1 times");
	game.set_seed(424242);
	item.check(game.draws() == 0, "set_seed resets the counter");
}

void check_game_rng_matches_seeded_rng() {
	Item item("rng.GameRng and SeededRng give one stream");
	GameRng game(424242);
	SeededRng plain(424242);
	for (int i = 0; i < 100; ++i) {
		item.check(same_double(game.random(), plain.next_float()), [&] { return format("draw %d", i); });
	}
	item.check(game.draws() == 100, "100 draws counted");
}

void check_fx_rng() {
	Item item("rng.FxRng is separate and seedable");
	GameRng game_a(424242);
	GameRng game_b(424242);
	FxRng fx(777);
	for (int i = 0; i < 200; ++i) {
		double a = game_a.random();
		// Effects drawn between the simulation's draws must not change them.
		fx.random();
		fx.rand_fx(-3.0, 3.0);
		fx.randi_fx(1, 6);
		fx.chance_fx(0.5);
		double b = game_b.random();
		item.check(same_double(a, b), [&] { return format("simulation draw %d unchanged by effect draws", i); });
	}
	item.check(game_a.draws() == 200, "200 draws counted");
	item.check(game_b.draws() == 200, "FxRng never touches GameRng.draws");
	FxRng fx_a(5);
	FxRng fx_b(5);
	FxRng fx_c(6);
	bool differs = false;
	for (int i = 0; i < 50; ++i) {
		double x = fx_a.random();
		item.check(same_double(x, fx_b.random()), "same seed, same effect stream");
		item.check(x >= 0.0 && x < 1.0, "random is in [0, 1)");
		if (!same_double(x, fx_c.random())) {
			differs = true;
		}
		int64_t r = fx_a.randi_fx(2, 4);
		fx_b.randi_fx(2, 4);
		item.check(r >= 2 && r <= 4, "randi_fx stays within its inclusive bounds");
		double f = fx_a.rand_fx(10.0, 20.0);
		fx_b.rand_fx(10.0, 20.0);
		item.check(f >= 10.0 && f < 20.0, "rand_fx stays within its bounds");
	}
	item.check(differs, "another seed gives another stream");
	// The default seed of FxRng is 0x9E3779B9 = 2654435769, the same stream as SeededRng(0).
	FxRng default_fx;
	SeededRng default_plain(0);
	item.check(default_fx.random() == default_plain.next_float(), "the default seed is 0x9E3779B9");
}

// ---- The test's own JSON reader --------------------------------------------------------------------------------------

void check_json_reader() {
	// The reader is test code, but a wrong reader would make every other item meaningless: it must refuse what it does
	// not understand instead of continuing.
	Item item("tests.golden_json reader");
	struct Case {
		const char *text;
		bool valid;
	};
	const Case cases[] = {
		{ "{\"a\": [1, -2, 0, \"x\", true, false, null, {}]}", true },
		{ "-9223372036854775808", true },
		{ "9223372036854775807", true },
		{ "\"\\u00e9\\ud83d\\ude00\\n\"", true },
		{ "9223372036854775808", false },
		{ "-9223372036854775809", false },
		{ "1.5", false },
		{ "1e3", false },
		{ "01", false },
		{ "-", false },
		{ "[1,", false },
		{ "[1 2]", false },
		{ "{\"a\" 1}", false },
		{ "\"abc", false },
		{ "\"\\ud83d\"", false },
		{ "true false", false },
		{ "nul", false },
		{ "", false },
	};
	for (const Case &c : cases) {
		Value v;
		std::string error;
		bool ok = golden::parse(c.text, &v, &error);
		item.check(ok == c.valid, [&] { return std::string("parse(") + c.text + ") " + (ok ? "succeeded" : "failed: " + error); });
	}
	std::string deep(static_cast<size_t>(golden::kMaxDepth) + 10, '[');
	Value v;
	std::string error;
	item.check(!golden::parse(deep, &v, &error), "nesting beyond the limit is refused without crashing");
	Value parsed;
	golden::parse("-9223372036854775808", &parsed, &error);
	item.check(parsed.integer == -9223372036854775807 - 1, "int64 minimum");
	std::vector<uint8_t> bytes;
	item.check(golden::base64_decode("AQID", &bytes) && bytes == std::vector<uint8_t>({ 1, 2, 3 }), "base64 without padding");
	item.check(golden::base64_decode("AQI=", &bytes) && bytes == std::vector<uint8_t>({ 1, 2 }), "base64 with one padding character");
	item.check(golden::base64_decode("AQ==", &bytes) && bytes == std::vector<uint8_t>({ 1 }), "base64 with two padding characters");
	item.check(!golden::base64_decode("AQ=", &bytes), "base64 with a wrong length");
	item.check(!golden::base64_decode("A*==", &bytes), "base64 with an invalid character");
	item.check(!golden::base64_decode("=AQI", &bytes), "base64 with padding in front");
}

// ---- The floating-point environment ----------------------------------------------------------------------------------------

void check_fp_environment() {
	Item item("fp_environment_ok");
	const char *reason = nullptr;
	bool ok = swarm::sim::fp_environment_ok(&reason);
	item.check(ok, [&] { return std::string("the floating-point environment is not suitable: ") + (reason != nullptr ? reason : "(no reason)"); });
	item.check(reason != nullptr && reason[0] == '\0', "no reason is given when the environment is fine");
	item.check(swarm::sim::fp_environment_ok(nullptr), "the reason may be omitted");
}

// ---- Benchmark -------------------------------------------------------------------------------------------------------------

constexpr size_t kBenchCalls = 400000;
volatile double g_bench_sink = 0.0; // keeps the timed calls from being optimised away
constexpr int kBenchRepeats = 5;

struct BenchInputs {
	std::vector<double> xs; // [-10, 10): angles within a few turns
	std::vector<double> ys; // [-300, 300): coordinates
	std::vector<double> es; // (-0.6, 0]: damping exponents
};

// Median and minimum of kBenchRepeats timed passes of `kBenchCalls` calls; `body(i)` returns a double that is
// accumulated so that the call cannot be optimised away.
template <typename Body>
void bench(const char *label, Body body) {
	double acc = 0.0;
	for (size_t i = 0; i < kBenchCalls / 10; ++i) { // warm-up
		acc += body(i);
	}
	double ns[kBenchRepeats];
	for (int r = 0; r < kBenchRepeats; ++r) {
		auto start = std::chrono::steady_clock::now();
		for (size_t i = 0; i < kBenchCalls; ++i) {
			acc += body(i);
		}
		auto stop = std::chrono::steady_clock::now();
		ns[r] = static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>(stop - start).count()) / static_cast<double>(kBenchCalls);
	}
	for (int a = 1; a < kBenchRepeats; ++a) { // insertion sort of five numbers
		for (int b = a; b > 0 && ns[b] < ns[b - 1]; --b) {
			double t = ns[b];
			ns[b] = ns[b - 1];
			ns[b - 1] = t;
		}
	}
	g_bench_sink = acc;
	std::printf("BENCH  %-28s median %8.1f ns/call   min %8.1f ns/call   (%.1f M calls/s)\n", label, ns[kBenchRepeats / 2], ns[0], 1000.0 / ns[kBenchRepeats / 2]);
}

void run_bench() {
	BenchInputs in;
	SeededRng rng(12345);
	in.xs.resize(kBenchCalls);
	in.ys.resize(kBenchCalls);
	in.es.resize(kBenchCalls);
	for (size_t i = 0; i < kBenchCalls; ++i) {
		in.xs[i] = rng.next_float() * 20.0 - 10.0;
		in.ys[i] = rng.next_float() * 600.0 - 300.0;
		in.es[i] = -rng.next_float() * 0.6;
	}
	const double *xs = in.xs.data();
	const double *ys = in.ys.data();
	const double *es = in.es.data();
	std::printf("BENCH  (%zu calls per pass, %d passes, steady_clock; the loop adds each result to a sum, about 1 ns per call)\n", kBenchCalls, kBenchRepeats);
	bench("(loop only: sum of xs[i])", [&](size_t i) { return xs[i]; });
	bench("js::sin", [&](size_t i) { return js::sin(xs[i]); });
	bench("js::cos", [&](size_t i) { return js::cos(xs[i]); });
	bench("js::atan", [&](size_t i) { return js::atan(xs[i]); });
	bench("js::atan2", [&](size_t i) { return js::atan2(ys[i], xs[i]); });
	bench("js::exp", [&](size_t i) { return js::exp(es[i]); });
	bench("js::log", [&](size_t i) { return js::log(std::fabs(ys[i]) + 1.0); });
	bench("js::hypot", [&](size_t i) { return js::hypot(ys[i], xs[i]); });
	bench("js::round", [&](size_t i) { return js::round(ys[i]); });
	bench("js::trunc", [&](size_t i) { return js::trunc(ys[i]); });
	bench("js::mod", [&](size_t i) { return js::mod(ys[i], 1e4); });
	bench("js::max", [&](size_t i) { return js::max(xs[i], ys[i]); });
	bench("js::min", [&](size_t i) { return js::min(xs[i], ys[i]); });
	bench("js::max5", [&](size_t i) { return js::max5(xs[i], ys[i], es[i], xs[i], ys[i]); });
	bench("js::clamp", [&](size_t i) { return js::clamp(ys[i], -100.0, 100.0); });
	bench("js::to_int32", [&](size_t i) { return static_cast<double>(js::to_int32(ys[i])); });
	bench("js::to_uint32", [&](size_t i) { return static_cast<double>(js::to_uint32(ys[i])); });
	bench("js::imul", [&](size_t i) { return static_cast<double>(js::imul(static_cast<int64_t>(i) + 7, 1831565813)); });
	bench("js::pow (x^0.7)", [&](size_t i) { return js::pow(std::fabs(xs[i]), 0.7); });
	SeededRng seeded(424242);
	GameRng game(424242);
	FxRng fx(1);
	bench("SeededRng::next_u32", [&](size_t) { return static_cast<double>(seeded.next_u32()); });
	bench("SeededRng::next_float", [&](size_t) { return seeded.next_float(); });
	bench("GameRng::random", [&](size_t) { return game.random(); });
	bench("GameRng::rand", [&](size_t) { return game.rand(-5.0, 5.0); });
	bench("GameRng::chance", [&](size_t) { return game.chance(0.5) ? 1.0 : 0.0; });
	bench("GameRng::index", [&](size_t) { return static_cast<double>(game.index(4)); });
	bench("FxRng::random", [&](size_t) { return fx.random(); });
	int shuffled[100];
	for (int i = 0; i < 100; ++i) {
		shuffled[i] = i;
	}
	bench("GameRng::shuffle (100 elements)", [&](size_t) {
		game.shuffle(shuffled, 100);
		return static_cast<double>(shuffled[0]);
	});
}

} // namespace

int main(int argc, char **argv) {
	std::string golden_dir;
	bool run_bench_requested = false;
	for (int i = 1; i < argc; ++i) {
		std::string arg = argv[i];
		if (arg == "--golden" && i + 1 < argc) {
			golden_dir = argv[++i];
		} else if (arg == "--bench") {
			run_bench_requested = true;
		} else {
			std::fprintf(stderr, "usage: swarm_sim_tests --golden <dir> [--bench]\n");
			return arg == "--help" || arg == "-h" ? 0 : 2;
		}
	}
	if (golden_dir.empty()) {
		std::fprintf(stderr, "usage: swarm_sim_tests --golden <dir> [--bench]\n");
		return 2;
	}

	// The environment first: if it is wrong, every other result is suspect.
	check_fp_environment();
	check_json_reader();

	Value math;
	{
		Item load("math.json loads");
		if (load_json(golden_dir + "/math.json", &math, &load)) {
			load.check(true, "");
		}
	}
	if (math.is(Value::Type::Object)) {
		check_math_vectors(math);
		check_named_cases(math);
	}
	check_empty_max_min();
	check_i32_boundaries();
	check_bit_helpers();

	Value rng;
	{
		Item load("rng.json loads");
		if (load_json(golden_dir + "/rng.json", &rng, &load)) {
			load.check(true, "");
		}
	}
	if (rng.is(Value::Type::Object)) {
		check_first_outputs(rng);
		check_checkpoints(rng);
		check_normalization(rng);
		check_game_rng_sequences(rng);
	}
	check_equal_streams();
	check_state_save_restore();
	check_helper_draw_counts();
	check_game_rng_matches_seeded_rng();
	check_fx_rng();

	bool passed = g_totals.failed_items == 0 && g_totals.items > 0;
	std::printf("SUMMARY: %" PRIu64 " items, %" PRIu64 " checks (math.json %" PRIu64 ", rng.json %" PRIu64 "), %" PRIu64 " failed\n", g_totals.items, g_totals.checks, g_totals.math_rows, g_totals.rng_rows, g_totals.failed_checks);
	if (run_bench_requested) {
		run_bench();
	}
	std::printf("RESULT: %s\n", passed ? "PASS" : "FAIL");
	return passed ? 0 : 1;
}
