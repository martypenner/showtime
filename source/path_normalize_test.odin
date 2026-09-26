package game

import "core:testing"
import norm "path_normalize"
import utf8 "core:unicode/utf8"

@(private = "file")
name_from_runes :: proc(runes: []rune) -> string {
	return utf8.runes_to_string(runes, context.temp_allocator)
}

@(private = "file")
expect_nfc :: proc(t: ^testing.T, input: []rune, expected: []rune) {
	got := norm.path_nfc(name_from_runes(input))
	testing.expect_value(t, got, name_from_runes(expected))
}

@(test)
path_nfc_ascii_passes_through :: proc(t: ^testing.T) {
	sword := [?]rune{0x53, 0x77, 0x6f, 0x72, 0x64}
	expect_nfc(t, sword[:], sword[:])
	testing.expect_value(t, norm.path_nfc(""), "")
}

@(test)
path_nfc_composes_decomposed_latin :: proc(t: ^testing.T) {
	cafe_nfd := [?]rune{0x63, 0x61, 0x66, 0x65, 0x301}
	cafe_nfc := [?]rune{0x63, 0x61, 0x66, 0xe9}
	fee_nfd := [?]rune{0x46, 0x65, 0x301, 0x65, 0x2d, 0x44, 0x72, 0x61, 0x67, 0x65, 0x301, 0x65}
	fee_nfc := [?]rune{0x46, 0xe9, 0x65, 0x2d, 0x44, 0x72, 0x61, 0x67, 0xe9, 0x65}
	expect_nfc(t, cafe_nfd[:], cafe_nfc[:])
	expect_nfc(t, fee_nfd[:], fee_nfc[:])
}

@(test)
path_nfc_decomposed_and_composed_spellings_agree :: proc(t: ^testing.T) {
	composed := [?]rune{0x4d, 0x6f, 0x74, 0xf6, 0x72, 0x68, 0x65, 0x61, 0x64}
	decomposed := [?]rune{0x4d, 0x6f, 0x74, 0x6f, 0x308, 0x72, 0x68, 0x65, 0x61, 0x64}
	expect_nfc(t, decomposed[:], composed[:])
}

@(test)
path_nfc_composes_multi_mark_and_blocks_same_class :: proc(t: ^testing.T) {
	u_dia_mac := [?]rune{0x75, 0x308, 0x304}
	u_dia_mac_nfc := [?]rune{0x1d6}
	n_circ_grave := [?]rune{0x6e, 0x302, 0x300}
	u_qam_dia := [?]rune{0x75, 0x5b8, 0x308}
	u_qam_dia_nfc := [?]rune{0xfc, 0x5b8}
	expect_nfc(t, u_dia_mac[:], u_dia_mac_nfc[:])
	expect_nfc(t, n_circ_grave[:], n_circ_grave[:])
	expect_nfc(t, u_qam_dia[:], u_qam_dia_nfc[:])
}

@(test)
path_nfc_hangul_round_trips :: proc(t: ^testing.T) {
	cho_jung_jong := [?]rune{0x1100, 0x1161, 0x11a8}
	syllable := [?]rune{0xac01}
	badeul := [?]rune{0x1103, 0x1161, 0x11a8}
	badeul_nfc := [?]rune{0xb2e5}
	expect_nfc(t, cho_jung_jong[:], syllable[:])
	expect_nfc(t, syllable[:], syllable[:])
	expect_nfc(t, badeul[:], badeul_nfc[:])
}

@(test)
path_nfc_respects_composition_exclusions :: proc(t: ^testing.T) {
	ka_nukta := [?]rune{0x915, 0x93c}
	ka_nukta_composed := [?]rune{0x958}
	expect_nfc(t, ka_nukta[:], ka_nukta[:])
	expect_nfc(t, ka_nukta_composed[:], ka_nukta[:])
}

@(test)
path_nfc_single_codepoint_decompositions :: proc(t: ^testing.T) {
	word_with_oxia := [?]rune{0x1f71}
	word_with_tonos := [?]rune{0x3ac}
	expect_nfc(t, word_with_oxia[:], word_with_tonos[:])
}

@(test)
path_nfc_is_idempotent :: proc(t: ^testing.T) {
	fee_nfd := [?]rune{0x46, 0x65, 0x301, 0x65, 0x2d, 0x44, 0x72, 0x61, 0x67, 0x65, 0x301, 0x65}
	once := norm.path_nfc(name_from_runes(fee_nfd[:]))
	testing.expect_value(t, norm.path_nfc(once), once)
}
