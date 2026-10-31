#include "golden_json.h"

#include <cstdio>
#include <utility>

namespace golden {

const Value *Value::find(const std::string &key) const {
	if (type != Type::Object) {
		return nullptr;
	}
	for (size_t i = 0; i < keys.size(); ++i) {
		if (keys[i] == key) {
			return &members[i];
		}
	}
	return nullptr;
}

namespace {

class Parser {
public:
	explicit Parser(const std::string &text) :
			s_(text) {}

	bool run(Value *out, std::string *error) {
		skip_space();
		if (!parse_value(out, 0)) {
			*error = error_;
			return false;
		}
		skip_space();
		if (pos_ != s_.size()) {
			fail("unexpected text after the document");
			*error = error_;
			return false;
		}
		return true;
	}

private:
	const std::string &s_;
	size_t pos_ = 0;
	std::string error_;

	bool fail(const char *message) {
		error_ = std::string(message) + " at byte " + std::to_string(pos_);
		return false;
	}

	bool at_end() const { return pos_ >= s_.size(); }

	void skip_space() {
		while (!at_end() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) {
			++pos_;
		}
	}

	bool consume(const char *word) {
		size_t n = 0;
		while (word[n] != '\0') {
			++n;
		}
		if (s_.compare(pos_, n, word) != 0) {
			return false;
		}
		pos_ += n;
		return true;
	}

	bool parse_value(Value *out, int depth) {
		if (depth > kMaxDepth) {
			return fail("nesting is too deep");
		}
		if (at_end()) {
			return fail("unexpected end of the document");
		}
		char c = s_[pos_];
		if (c == '{') {
			return parse_object(out, depth);
		}
		if (c == '[') {
			return parse_array(out, depth);
		}
		if (c == '"') {
			out->type = Value::Type::String;
			return parse_string(&out->string);
		}
		if (c == '-' || (c >= '0' && c <= '9')) {
			return parse_integer(out);
		}
		if (consume("true")) {
			out->type = Value::Type::Bool;
			out->boolean = true;
			return true;
		}
		if (consume("false")) {
			out->type = Value::Type::Bool;
			out->boolean = false;
			return true;
		}
		if (consume("null")) {
			out->type = Value::Type::Null;
			return true;
		}
		return fail("unexpected character");
	}

	bool parse_object(Value *out, int depth) {
		out->type = Value::Type::Object;
		++pos_; // '{'
		skip_space();
		if (!at_end() && s_[pos_] == '}') {
			++pos_;
			return true;
		}
		while (true) {
			skip_space();
			if (at_end() || s_[pos_] != '"') {
				return fail("expected a member name");
			}
			std::string key;
			if (!parse_string(&key)) {
				return false;
			}
			skip_space();
			if (at_end() || s_[pos_] != ':') {
				return fail("expected ':'");
			}
			++pos_;
			skip_space();
			Value member;
			if (!parse_value(&member, depth + 1)) {
				return false;
			}
			out->keys.push_back(std::move(key));
			out->members.push_back(std::move(member));
			skip_space();
			if (at_end()) {
				return fail("unexpected end inside an object");
			}
			if (s_[pos_] == ',') {
				++pos_;
				continue;
			}
			if (s_[pos_] == '}') {
				++pos_;
				return true;
			}
			return fail("expected ',' or '}'");
		}
	}

	bool parse_array(Value *out, int depth) {
		out->type = Value::Type::Array;
		++pos_; // '['
		skip_space();
		if (!at_end() && s_[pos_] == ']') {
			++pos_;
			return true;
		}
		while (true) {
			skip_space();
			Value element;
			if (!parse_value(&element, depth + 1)) {
				return false;
			}
			out->array.push_back(std::move(element));
			skip_space();
			if (at_end()) {
				return fail("unexpected end inside an array");
			}
			if (s_[pos_] == ',') {
				++pos_;
				continue;
			}
			if (s_[pos_] == ']') {
				++pos_;
				return true;
			}
			return fail("expected ',' or ']'");
		}
	}

	static int hex_digit(char c) {
		if (c >= '0' && c <= '9') {
			return c - '0';
		}
		if (c >= 'a' && c <= 'f') {
			return c - 'a' + 10;
		}
		if (c >= 'A' && c <= 'F') {
			return c - 'A' + 10;
		}
		return -1;
	}

	bool parse_hex4(uint32_t *out) {
		if (pos_ + 4 > s_.size()) {
			return fail("truncated \\u escape");
		}
		uint32_t v = 0;
		for (int i = 0; i < 4; ++i) {
			int d = hex_digit(s_[pos_ + static_cast<size_t>(i)]);
			if (d < 0) {
				return fail("bad \\u escape");
			}
			v = v * 16 + static_cast<uint32_t>(d);
		}
		pos_ += 4;
		*out = v;
		return true;
	}

	static void append_utf8(std::string *out, uint32_t cp) {
		if (cp < 0x80) {
			out->push_back(static_cast<char>(cp));
		} else if (cp < 0x800) {
			out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
			out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else if (cp < 0x10000) {
			out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
			out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		} else {
			out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
			out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
			out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
			out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
		}
	}

	bool parse_string(std::string *out) {
		++pos_; // opening quote
		out->clear();
		while (true) {
			if (at_end()) {
				return fail("unterminated string");
			}
			unsigned char c = static_cast<unsigned char>(s_[pos_]);
			if (c == '"') {
				++pos_;
				return true;
			}
			if (c < 0x20) {
				return fail("control character in a string");
			}
			if (c != '\\') {
				out->push_back(static_cast<char>(c));
				++pos_;
				continue;
			}
			++pos_;
			if (at_end()) {
				return fail("unterminated escape");
			}
			char e = s_[pos_++];
			switch (e) {
				case '"': out->push_back('"'); break;
				case '\\': out->push_back('\\'); break;
				case '/': out->push_back('/'); break;
				case 'b': out->push_back('\b'); break;
				case 'f': out->push_back('\f'); break;
				case 'n': out->push_back('\n'); break;
				case 'r': out->push_back('\r'); break;
				case 't': out->push_back('\t'); break;
				case 'u': {
					uint32_t cp;
					if (!parse_hex4(&cp)) {
						return false;
					}
					if (cp >= 0xD800 && cp <= 0xDBFF) { // a high surrogate must be followed by a low one
						uint32_t low;
						if (!consume("\\u") || !parse_hex4(&low)) {
							return fail("lone high surrogate");
						}
						if (low < 0xDC00 || low > 0xDFFF) {
							return fail("bad low surrogate");
						}
						cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
					} else if (cp >= 0xDC00 && cp <= 0xDFFF) {
						return fail("lone low surrogate");
					}
					append_utf8(out, cp);
					break;
				}
				default:
					return fail("unknown escape");
			}
		}
	}

	// -?(0|[1-9][0-9]*) and nothing else: a '.', 'e' or 'E' after the digits is an error (the golden files have no such numbers).
	bool parse_integer(Value *out) {
		bool negative = false;
		if (s_[pos_] == '-') {
			negative = true;
			++pos_;
		}
		if (at_end() || s_[pos_] < '0' || s_[pos_] > '9') {
			return fail("expected a digit");
		}
		if (s_[pos_] == '0' && pos_ + 1 < s_.size() && s_[pos_ + 1] >= '0' && s_[pos_ + 1] <= '9') {
			return fail("leading zero in a number");
		}
		uint64_t magnitude = 0;
		while (!at_end() && s_[pos_] >= '0' && s_[pos_] <= '9') {
			uint64_t digit = static_cast<uint64_t>(s_[pos_] - '0');
			if (magnitude > (UINT64_MAX - digit) / 10) {
				return fail("integer out of range");
			}
			magnitude = magnitude * 10 + digit;
			++pos_;
		}
		if (!at_end() && (s_[pos_] == '.' || s_[pos_] == 'e' || s_[pos_] == 'E')) {
			return fail("a number that is not an integer");
		}
		const uint64_t kInt64MaxMagnitude = 9223372036854775807ull;
		if (negative ? magnitude > kInt64MaxMagnitude + 1 : magnitude > kInt64MaxMagnitude) {
			return fail("integer out of range");
		}
		out->type = Value::Type::Int;
		if (!negative) {
			out->integer = static_cast<int64_t>(magnitude);
		} else if (magnitude == 0) {
			out->integer = 0;
		} else {
			out->integer = -static_cast<int64_t>(magnitude - 1) - 1;
		}
		return true;
	}
};

int base64_value(char c) {
	if (c >= 'A' && c <= 'Z') {
		return c - 'A';
	}
	if (c >= 'a' && c <= 'z') {
		return c - 'a' + 26;
	}
	if (c >= '0' && c <= '9') {
		return c - '0' + 52;
	}
	if (c == '+') {
		return 62;
	}
	if (c == '/') {
		return 63;
	}
	return -1;
}

} // namespace

bool parse(const std::string &text, Value *out, std::string *error) {
	*out = Value();
	Parser parser(text);
	return parser.run(out, error);
}

bool base64_decode(const std::string &text, std::vector<uint8_t> *out) {
	out->clear();
	if (text.size() % 4 != 0) {
		return false;
	}
	out->reserve(text.size() / 4 * 3);
	for (size_t i = 0; i < text.size(); i += 4) {
		int v[4];
		int padding = 0;
		for (size_t j = 0; j < 4; ++j) {
			char c = text[i + j];
			if (c == '=') {
				// padding only in the last group, at its end
				if (i + 4 != text.size() || j < 2) {
					return false;
				}
				++padding;
				v[j] = 0;
			} else {
				if (padding != 0) {
					return false;
				}
				v[j] = base64_value(c);
				if (v[j] < 0) {
					return false;
				}
			}
		}
		uint32_t triple = (static_cast<uint32_t>(v[0]) << 18) | (static_cast<uint32_t>(v[1]) << 12) | (static_cast<uint32_t>(v[2]) << 6) | static_cast<uint32_t>(v[3]);
		out->push_back(static_cast<uint8_t>(triple >> 16));
		if (padding < 2) {
			out->push_back(static_cast<uint8_t>((triple >> 8) & 0xFF));
		}
		if (padding < 1) {
			out->push_back(static_cast<uint8_t>(triple & 0xFF));
		}
	}
	return true;
}

bool read_file(const std::string &path, std::string *out, std::string *error) {
	std::FILE *file = std::fopen(path.c_str(), "rb");
	if (file == nullptr) {
		*error = "cannot open " + path;
		return false;
	}
	out->clear();
	char buffer[65536];
	while (true) {
		size_t got = std::fread(buffer, 1, sizeof buffer, file);
		out->append(buffer, got);
		if (got < sizeof buffer) {
			break;
		}
	}
	bool failed = std::ferror(file) != 0;
	std::fclose(file);
	if (failed) {
		*error = "cannot read " + path;
		return false;
	}
	return true;
}

} // namespace golden
