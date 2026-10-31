#ifndef SWARM_TESTS_GOLDEN_JSON_H
#define SWARM_TESTS_GOLDEN_JSON_H

// A minimal JSON reader and a base64 decoder for the golden files of godot/tests/golden (math.json, rng.json). Test code
// only: it is not part of the library. The golden files hold objects, arrays, strings, booleans, null and integers
// (doubles travel as 16 hex digits or as base64 of little-endian bytes, see godot/tests/golden_codec.gd); the reader
// accepts exactly that and reports everything else (a number with a fraction or an exponent, an integer beyond int64,
// malformed text, nesting deeper than kMaxDepth) as an error instead of guessing.

#include <cstdint>
#include <string>
#include <vector>

namespace golden {

struct Value {
	enum class Type { Null, Bool, Int, String, Array, Object };

	Type type = Type::Null;
	bool boolean = false;
	int64_t integer = 0;
	std::string string;
	std::vector<Value> array;
	std::vector<std::string> keys; // an object: the member names in file order ...
	std::vector<Value> members; // ... and the member values

	// The member of an object with this name, or nullptr (also when this is not an object).
	const Value *find(const std::string &key) const;
	bool is(Type t) const { return type == t; }
};

constexpr int kMaxDepth = 64;

// Parses `text`. On failure returns false and describes the problem and its byte offset in *error.
bool parse(const std::string &text, Value *out, std::string *error);

// Standard base64 with '=' padding. Returns false for an invalid character, a wrong length or misplaced padding.
bool base64_decode(const std::string &text, std::vector<uint8_t> *out);

// The whole file, or false (and *error) when it cannot be read.
bool read_file(const std::string &path, std::string *out, std::string *error);

} // namespace golden

#endif // SWARM_TESTS_GOLDEN_JSON_H
