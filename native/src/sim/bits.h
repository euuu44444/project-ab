#ifndef SWARM_SIM_BITS_H
#define SWARM_SIM_BITS_H

// double <-> IEEE-754 bit pattern and 32-bit integer helpers. Kept free of Godot headers (native/src/sim is plain
// C++17, see tools/check_native_sources.py). The conversions use memcpy: no union and no pointer cast.

#include <cstdint>
#include <cstring>

namespace swarm::sim {

// The IEEE-754 bit pattern of x (JsMath.to_bits; the GDScript version returns it as a signed int64).
inline uint64_t to_bits(double x) {
	uint64_t bits;
	std::memcpy(&bits, &x, sizeof bits);
	return bits;
}

// The double with the given bit pattern (JsMath.from_bits).
inline double from_bits(uint64_t bits) {
	double x;
	std::memcpy(&x, &bits, sizeof x);
	return x;
}

// High and low 32 bits of x (fdlibm GET_HIGH_WORD / GET_LOW_WORD).
inline uint32_t high_word(double x) {
	return static_cast<uint32_t>(to_bits(x) >> 32);
}

inline uint32_t low_word(double x) {
	return static_cast<uint32_t>(to_bits(x));
}

// x with its high word replaced (fdlibm SET_HIGH_WORD); the low word is kept.
inline double with_high_word(double x, uint32_t high) {
	return from_bits((static_cast<uint64_t>(high) << 32) | (to_bits(x) & 0xFFFFFFFFu));
}

// The int32 whose two's complement bit pattern is v. Written without relying on the conversion of an out-of-range
// value to a signed type (implementation-defined before C++20).
inline int32_t as_int32(uint32_t v) {
	return v <= 0x7FFFFFFFu ? static_cast<int32_t>(v) : static_cast<int32_t>(static_cast<int64_t>(v) - 4294967296);
}

// v >> n for n in [0, 31] as an arithmetic shift (rounds toward minus infinity), without relying on the
// implementation-defined right shift of a negative value.
inline int32_t arithmetic_shift_right(int32_t v, uint32_t n) {
	return v >= 0 ? (v >> n) : ~((~v) >> n);
}

} // namespace swarm::sim

#endif // SWARM_SIM_BITS_H
