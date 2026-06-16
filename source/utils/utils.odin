// Wraps os.read_entire_file and os.write_entire_file, but they also work with emscripten.

package utils

import "core:crypto/hash"
import "core:encoding/hex"
import "core:io"

@(require_results)
read_entire_file :: proc(
	name: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	data: []byte,
	success: bool,
) {
	return _read_entire_file(name, allocator, loc)
}

write_entire_file :: proc(name: string, data: []byte, truncate := true) -> (success: bool) {
	return _write_entire_file(name, data, truncate)
}

hash_bytes :: proc(data: []byte) -> (string, io.Error) {
	file_hash := hash.hash_bytes(hash.Algorithm.BLAKE2B, data, context.temp_allocator)
	hex_hash, hex_err := hex.encode(file_hash, context.temp_allocator)
	if hex_err != nil do return "", io.Error.Unknown
	return string(hex_hash), nil
}
