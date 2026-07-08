package osc

import "core:log"
import "core:net"

string_append :: proc(packet: ^[dynamic]byte, s: string) {
	append(packet, ..transmute([]byte)s)
	append(packet, 0)

	for len(packet^) % 4 != 0 {
		append(packet, 0)
	}
}

f32_append :: proc(packet: ^[dynamic]byte, value: f32) {
	bits := transmute(u32)value

	// OSC uses big-endian numbers.
	append(packet, byte(bits >> 24))
	append(packet, byte(bits >> 16))
	append(packet, byte(bits >> 8))
	append(packet, byte(bits))
}

float_send :: proc(socket: net.UDP_Socket, endpoint: net.Endpoint, address: string, value: f32) {
	packet := make([dynamic]byte, context.temp_allocator)

	string_append(&packet, address)
	string_append(&packet, ",f")
	f32_append(&packet, value)

	bytes_written, err := net.send_udp(socket, packet[:], endpoint)
	if err != nil {
		log.errorf("lighting send failed after %d bytes: %v", bytes_written, err)
	}
}
